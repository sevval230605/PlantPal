import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';

// İki paketin takma adları farklı olmalı.
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Saat dilimi ve bildirim altyapısını hazırla.
  await PlantPalNotifications.initialize();

  // Kayıtlı verileri uygulama başlamadan önce yükle.
  await PlantPalStorage.load();

  // Her değişiklikte ilgili veriyi cihaz hafızasına kaydet.
  cartItems.addListener(() => PlantPalStorage.saveCart(cartItems.value));

  favoritePlants.addListener(
    () => PlantPalStorage.saveFavorites(favoritePlants.value),
  );

  wateredPlants.addListener(
    () => PlantPalStorage.saveWatered(wateredPlants.value),
  );

  lastWateredDates.addListener(() {
    PlantPalStorage.saveWateringDates(lastWateredDates.value);
    PlantPalNotifications.refreshAllReminders();
  });

  orderHistory.addListener(
    () => PlantPalStorage.saveOrders(orderHistory.value),
  );

  // Önceden kaydedilmiş sulama tarihlerine göre bildirimleri yeniden planla.
  await PlantPalNotifications.refreshAllReminders();

  runApp(const PlantPalApp());
}

const Color primaryGreen = Color(0xFF315C43);
const Color backgroundColor = Color(0xFFF7F8F2);

// Sepet verileri
final ValueNotifier<List<Plant>> cartItems = ValueNotifier<List<Plant>>([]);

// Favori verileri
final ValueNotifier<List<Plant>> favoritePlants = ValueNotifier<List<Plant>>(
  [],
);

// Sulanan bitkileri takip eder.
final ValueNotifier<Set<String>> wateredPlants = ValueNotifier<Set<String>>({});

// Her bitkinin son sulandığı tarihi saklar.
final ValueNotifier<Map<String, DateTime>> lastWateredDates =
    ValueNotifier<Map<String, DateTime>>({});

// Sipariş geçmişi
final ValueNotifier<List<OrderRecord>> orderHistory =
    ValueNotifier<List<OrderRecord>>([]);

void toggleFavorite(Plant plant) {
  final updated = [...favoritePlants.value];

  if (updated.any((item) => item.name == plant.name)) {
    updated.removeWhere((item) => item.name == plant.name);
  } else {
    updated.add(plant);
  }

  favoritePlants.value = updated;
}

// Yerel sulama bildirimlerini yöneten servis.
class PlantPalNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static const AndroidNotificationDetails _androidDetails =
      AndroidNotificationDetails(
        'plantpal_watering_channel',
        'Bitki sulama hatırlatmaları',
        channelDescription: 'Bitkilerin sulama zamanı geldiğinde hatırlatır.',
        importance: Importance.high,
        priority: Priority.high,
      );

  static Future<void> initialize() async {
    if (_initialized) return;

    tzdata.initializeTimeZones();

    try {
      final localTimezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTimezone.identifier));
    } catch (_) {
      // Saat dilimi alınamazsa Türkiye saat dilimini kullan.
      tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));
    }

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _plugin.initialize(initializationSettings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // Android 13 ve üzeri bildirim iznini ister.
    await androidPlugin?.requestNotificationsPermission();

    _initialized = true;
  }

  static int _notificationId(String plantName) =>
      plantName.codeUnits.fold<int>(0, (value, unit) => value + unit);

  static Future<void> refreshAllReminders() async {
    if (!_initialized) return;

    for (final plant in plantList) {
      await scheduleReminder(plant);
    }
  } // Bildirim sistemini anında test etmek için geçici fonksiyon.

  static Future<void> scheduleReminder(Plant plant) async {
    if (!_initialized) return;

    final lastWatered = lastWateredDates.value[plant.name];

    if (lastWatered == null) {
      await _plugin.cancel(_notificationId(plant.name));
      return;
    }

    final dueDate = lastWatered.add(Duration(days: plant.wateringIntervalDays));
    final scheduledDate = DateTime(dueDate.year, dueDate.month, dueDate.day, 9);
    final now = DateTime.now();

    if (!scheduledDate.isAfter(now)) {
      await _plugin.cancel(_notificationId(plant.name));
      return;
    }

    await _plugin.zonedSchedule(
      _notificationId(plant.name),
      'Sulama zamanı yaklaşıyor 🌱',
      '${plant.name} bitkini kontrol etmeyi unutma.',
      tz.TZDateTime.from(scheduledDate, tz.local),
      const NotificationDetails(android: _androidDetails),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: plant.name,
    );
  }
}

// Bir bitki sulandığında tarihi kaydeder ve sonraki hatırlatmayı planlar.
Future<void> markPlantAsWatered(Plant plant) async {
  final now = DateTime.now();

  lastWateredDates.value = {...lastWateredDates.value, plant.name: now};

  wateredPlants.value = {...wateredPlants.value, plant.name};

  await PlantPalNotifications.scheduleReminder(plant);
}

DateTime? nextWateringDate(Plant plant) {
  final lastWatered = lastWateredDates.value[plant.name];

  if (lastWatered == null) return null;

  return lastWatered.add(Duration(days: plant.wateringIntervalDays));
}

bool isWateringDue(Plant plant) {
  final nextDate = nextWateringDate(plant);

  return nextDate == null || !nextDate.isAfter(DateTime.now());
}

String formatShortDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}.'
    '${date.month.toString().padLeft(2, '0')}.'
    '${date.year}';

// Uygulama
class PlantPalApp extends StatelessWidget {
  const PlantPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PlantPal',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: ColorScheme.fromSeed(seedColor: primaryGreen),
      ),
      home: const HomeScreen(),
    );
  }
}

// Bitki veri modeli
class Plant {
  final String name;
  final String category;
  final int price;
  final String emoji;
  final String description;
  final String water;
  final String sunlight;

  // Başlangıç sulama aralıklarıdır.
  // Gerçek sulama ihtiyacı toprağa ve ortam koşullarına göre değişebilir.
  int get wateringIntervalDays {
    switch (name) {
      case 'Monstera':
      case 'Areka Palmiyesi':
        return 7;
      case 'Barış Çiçeği':
        return 4;
      case 'Orkide':
        return 7;
      case 'Sukulent':
      case 'Aloe Vera':
      case 'Lavanta':
        return 14;
      case 'Kaktüs':
        return 21;
      default:
        return 7;
    }
  }

  const Plant({
    required this.name,
    required this.category,
    required this.price,
    required this.emoji,
    required this.description,
    required this.water,
    required this.sunlight,
  });
} // Bitki kataloğu

const List<Plant> plantList = [
  Plant(
    name: 'Monstera',
    category: 'Salon Bitkisi',
    price: 450,
    emoji: '🌿',
    description: 'Geniş ve dekoratif yapraklarıyla yaşam alanlarına doğal bir görünüm kazandırır.',
    water: 'Haftada 1-2 kez',
    sunlight: 'Dolaylı ışık',
  ),
  Plant(
    name: 'Sukulent',
    category: 'Sukulent',
    price: 180,
    emoji: '🪴',
    description:
        'Az bakım isteyen, suyu yapraklarında depolayan sevimli bir bitkidir.',
    water: 'Toprak kurudukça',
    sunlight: 'Bol aydınlık',
  ),
  Plant(
    name: 'Barış Çiçeği',
    category: 'Çiçekli Bitki',
    price: 320,
    emoji: '🌸',
    description:
        'Beyaz çiçekleri ve yeşil yapraklarıyla evlerde sık tercih edilir.',
    water: 'Haftada 2 kez',
    sunlight: 'Dolaylı ışık',
  ),
  Plant(
    name: 'Kaktüs',
    category: 'Sukulent',
    price: 150,
    emoji: '🌵',
    description:
        'Dayanıklı yapısı sayesinde az suyla yaşayabilen bir bitkidir.',
    water: 'Toprak kurudukça',
    sunlight: 'Bol güneş',
  ),
  Plant(
    name: 'Orkide',
    category: 'Çiçekli Bitki',
    price: 550,
    emoji: '🌺',
    description: 'Zarif çiçekleriyle bulunduğu ortama şıklık katar.',
    water: 'Haftada 1 kez',
    sunlight: 'Dolaylı ışık',
  ),
  Plant(
    name: 'Aloe Vera',
    category: 'Sukulent',
    price: 220,
    emoji: '🌱',
    description: 'Etli yapraklarıyla bilinen, bakımı kolay bir bitkidir.',
    water: 'Toprak kurudukça',
    sunlight: 'Aydınlık ortam',
  ),
  Plant(
    name: 'Areka Palmiyesi',
    category: 'Salon Bitkisi',
    price: 680,
    emoji: '🌴',
    description:
        'Tüylü yapraklarıyla iç mekanlarda tropikal bir atmosfer oluşturur.',
    water: 'Haftada 1-2 kez',
    sunlight: 'Dolaylı ışık',
  ),
  Plant(
    name: 'Lavanta',
    category: 'Çiçekli Bitki',
    price: 280,
    emoji: '🪻',
    description:
        'Hoş kokusu ve mor çiçekleriyle tanınan aromatik bir bitkidir.',
    water: 'Toprak kurudukça',
    sunlight: 'Bol güneş',
  ),
];

// Tamamlanan siparişlerin veri modeli
class OrderRecord {
  final String customerName;
  final String phone;
  final String address;
  final List<String> plantNames;
  final int totalPrice;
  final DateTime orderDate;

  OrderRecord({
    required this.customerName,
    required this.phone,
    required this.address,
    required this.plantNames,
    required this.totalPrice,
    required this.orderDate,
  });

  // Sipariş bilgisini JSON formatına dönüştürür.
  Map<String, dynamic> toJson() {
    return {
      'customerName': customerName,
      'phone': phone,
      'address': address,
      'plantNames': plantNames,
      'totalPrice': totalPrice,
      'orderDate': orderDate.toIso8601String(),
    };
  }

  // Kaydedilmiş JSON bilgisini sipariş nesnesine dönüştürür.
  factory OrderRecord.fromJson(Map<String, dynamic> json) {
    return OrderRecord(
      customerName: json['customerName'] as String,
      phone: json['phone'] as String,
      address: json['address'] as String,
      plantNames: List<String>.from(json['plantNames'] as List),
      totalPrice: json['totalPrice'] as int,
      orderDate: DateTime.parse(json['orderDate'] as String),
    );
  }
}

// Uygulama verilerini cihazın yerel hafızasında saklar.
class PlantPalStorage {
  static const String _cartKey = 'plantpal_cart';
  static const String _favoritesKey = 'plantpal_favorites';
  static const String _wateredKey = 'plantpal_watered';
  static const String _wateringDatesKey = 'plantpal_watering_dates';
  static const String _ordersKey = 'plantpal_orders';

  static Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();

    // Kayıtlı bitki isimlerini gerçek Plant nesnelerine dönüştürür.
    List<Plant> restorePlants(String key) {
      final savedNames = preferences.getStringList(key) ?? <String>[];

      return savedNames
          .map((name) => plantList.firstWhere((plant) => plant.name == name))
          .toList();
    }

    cartItems.value = restorePlants(_cartKey);
    favoritePlants.value = restorePlants(_favoritesKey);

    wateredPlants.value = (preferences.getStringList(_wateredKey) ?? <String>[])
        .toSet();

    // Kayıtlı son sulama tarihlerini geri yükle.
    final savedDates = preferences.getString(_wateringDatesKey);

    if (savedDates != null) {
      final decoded = jsonDecode(savedDates) as Map<String, dynamic>;

      lastWateredDates.value = decoded.map(
        (name, date) => MapEntry(name, DateTime.parse(date as String)),
      );
    }

    // Daha önce tamamlanan siparişleri geri yükler.
    final savedOrders = preferences.getStringList(_ordersKey) ?? <String>[];

    orderHistory.value = savedOrders
        .map(
          (item) =>
              OrderRecord.fromJson(jsonDecode(item) as Map<String, dynamic>),
        )
        .toList();
  }

  static Future<void> saveCart(List<Plant> plants) async {
    final preferences = await SharedPreferences.getInstance();

    await preferences.setStringList(
      _cartKey,
      plants.map((plant) => plant.name).toList(),
    );
  }

  static Future<void> saveFavorites(List<Plant> plants) async {
    final preferences = await SharedPreferences.getInstance();

    await preferences.setStringList(
      _favoritesKey,
      plants.map((plant) => plant.name).toList(),
    );
  }

  static Future<void> saveWatered(Set<String> plantNames) async {
    final preferences = await SharedPreferences.getInstance();

    await preferences.setStringList(_wateredKey, plantNames.toList());
  }

  // Son sulama tarihlerini JSON olarak cihaz hafızasına kaydeder.
  static Future<void> saveWateringDates(Map<String, DateTime> dates) async {
    final preferences = await SharedPreferences.getInstance();

    final encoded = dates.map(
      (name, date) => MapEntry(name, date.toIso8601String()),
    );

    await preferences.setString(_wateringDatesKey, jsonEncode(encoded));
  }

  // Sipariş geçmişini JSON olarak cihaz hafızasına kaydeder.
  static Future<void> saveOrders(List<OrderRecord> orders) async {
    final preferences = await SharedPreferences.getInstance();

    await preferences.setStringList(
      _ordersKey,
      orders.map((order) => jsonEncode(order.toJson())).toList(),
    );
  }
} // Ana ekran ve alt menü

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: backgroundColor,
        title: const Row(
          children: [
            Icon(Icons.eco, color: primaryGreen),
            SizedBox(width: 8),
            Text(
              'PlantPal',
              style: TextStyle(
                color: primaryGreen,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sipariş geçmişim',
            icon: const Icon(Icons.receipt_long_outlined, color: primaryGreen),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const OrderHistoryPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: selectedIndex,
        children: const [
          HomePage(),
          CatalogPage(),
          FavoritesPage(),
          CarePage(),
          CartPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Ana Sayfa',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_florist_outlined),
            label: 'Katalog',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: 'Favoriler',
          ),
          NavigationDestination(
            icon: Icon(Icons.water_drop_outlined),
            selectedIcon: Icon(Icons.water_drop),
            label: 'Bakım',
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_bag_outlined),
            label: 'Sepet',
          ),
        ],
      ),
    );
  }
}

// Ana sayfa
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: primaryGreen,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Doğayı evine taşı!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Bitkileri keşfet, bakım bilgilerini öğren ve yaşam alanını güzelleştir.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                SizedBox(height: 18),
                Text('🌿  🪴  🌱', style: TextStyle(fontSize: 35)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Popüler Bitkiler',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF26372C),
              ),
            ),
          ),
          const SizedBox(height: 15),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: 4,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 15,
              mainAxisSpacing: 15,
              childAspectRatio: 0.85,
            ),
            itemBuilder: (context, index) {
              return PlantCard(plant: plantList[index]);
            },
          ),
        ],
      ),
    );
  }
}

// Ortak bitki kartı
class PlantCard extends StatelessWidget {
  final Plant plant;

  const PlantCard({super.key, required this.plant});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showPlantDetails(context, plant),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ValueListenableBuilder<List<Plant>>(
                  valueListenable: favoritePlants,
                  builder: (context, favorites, child) {
                    final favorite = favorites.any(
                      (item) => item.name == plant.name,
                    );

                    return IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        favorite ? Icons.favorite : Icons.favorite_border,
                        color: favorite ? Colors.redAccent : Colors.grey,
                      ),
                      onPressed: () => toggleFavorite(plant),
                    );
                  },
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: Text(plant.emoji, style: const TextStyle(fontSize: 55)),
              ),
            ),
            Text(
              plant.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 5),
            Text(
              plant.category,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 7),
            Text(
              '${plant.price} TL',
              style: const TextStyle(
                color: primaryGreen,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Bitki kataloğu
class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  String searchText = '';
  String selectedCategory = 'Tümü';

  final List<String> categories = [
    'Tümü',
    'Salon Bitkisi',
    'Sukulent',
    'Çiçekli Bitki',
  ];

  @override
  Widget build(BuildContext context) {
    final filteredPlants = plantList.where((plant) {
      final matchesSearch = plant.name.toLowerCase().contains(
        searchText.toLowerCase(),
      );

      final matchesCategory =
          selectedCategory == 'Tümü' || plant.category == selectedCategory;

      return matchesSearch && matchesCategory;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 15, 20, 12),
          child: Text(
            'Bitki Kataloğu 🌿',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: primaryGreen,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            onChanged: (value) {
              setState(() {
                searchText = value;
              });
            },
            decoration: InputDecoration(
              hintText: 'Bitki ara...',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 15),
        SizedBox(
          height: 42,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final category = categories[index];
              final isSelected = selectedCategory == category;

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(category),
                  selected: isSelected,
                  selectedColor: primaryGreen,
                  backgroundColor: Colors.white,
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : primaryGreen,
                    fontWeight: FontWeight.w600,
                  ),
                  onSelected: (_) {
                    setState(() {
                      selectedCategory = category;
                    });
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 15),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '${filteredPlants.length} bitki bulundu',
            style: const TextStyle(color: Colors.grey, fontSize: 14),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: filteredPlants.isEmpty
              ? const Center(
                  child: Text(
                    'Aradığın bitki bulunamadı 🌱',
                    style: TextStyle(fontSize: 16),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: filteredPlants.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 15,
                    mainAxisSpacing: 15,
                    childAspectRatio: 0.85,
                  ),
                  itemBuilder: (context, index) {
                    return PlantCard(plant: filteredPlants[index]);
                  },
                ),
        ),
      ],
    );
  }
}

// Bitki detay penceresi
void showPlantDetails(BuildContext context, Plant plant) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(plant.emoji, style: const TextStyle(fontSize: 85)),
              ),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plant.name,
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                        color: primaryGreen,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<List<Plant>>(
                    valueListenable: favoritePlants,
                    builder: (context, favorites, child) {
                      final favorite = favorites.any(
                        (item) => item.name == plant.name,
                      );

                      return IconButton(
                        tooltip: favorite
                            ? 'Favorilerden kaldır'
                            : 'Favorilere ekle',
                        icon: Icon(
                          favorite ? Icons.favorite : Icons.favorite_border,
                          color: favorite ? Colors.redAccent : primaryGreen,
                          size: 28,
                        ),
                        onPressed: () => toggleFavorite(plant),
                      );
                    },
                  ),
                ],
              ),
              Text(plant.category, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              Text(
                plant.description,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const Divider(height: 30),
              Text('💧 Sulama: ${plant.water}'),
              const SizedBox(height: 10),
              Text('☀️ Işık ihtiyacı: ${plant.sunlight}'),
              const SizedBox(height: 15),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primaryGreen,
                    side: const BorderSide(color: primaryGreen),
                    padding: const EdgeInsets.all(13),
                  ),
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('Bakım Takvimini Gör'),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CareGuidePage(plant: plant),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 15),
              Text(
                '${plant.price} TL',
                style: const TextStyle(
                  color: primaryGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(15),
                  ),
                  onPressed: () {
                    cartItems.value = [...cartItems.value, plant];

                    Navigator.pop(context);

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${plant.name} sepete eklendi! 🌱'),
                      ),
                    );
                  },
                  child: const Text('Sepete Ekle'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

// Favoriler ekranı
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Plant>>(
      valueListenable: favoritePlants,
      builder: (context, favorites, child) {
        if (favorites.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.favorite_border, size: 75, color: primaryGreen),
                SizedBox(height: 15),
                Text(
                  'Henüz favorin yok 🌱',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: primaryGreen,
                  ),
                ),
                SizedBox(height: 8),
                Text('Beğendiğin bitkileri kalp simgesine basarak kaydet.'),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(
                'Favori Bitkilerim 💚',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: primaryGreen,
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(20, 5, 20, 20),
                itemCount: favorites.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 15,
                  mainAxisSpacing: 15,
                  childAspectRatio: 0.85,
                ),
                itemBuilder: (context, index) {
                  return PlantCard(plant: favorites[index]);
                },
              ),
            ),
          ],
        );
      },
    );
  }
} // Bakım ekranı

class CarePage extends StatelessWidget {
  const CarePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, DateTime>>(
      valueListenable: lastWateredDates,
      builder: (context, dates, child) {
        final duePlants = plantList.where(isWateringDue).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                'Bitki Bakım Takvimi 🌱',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: primaryGreen,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Bitkilerinin sulama zamanlarını takip et ve bakımını unutma.',
                style: TextStyle(color: Colors.grey, height: 1.4),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: primaryGreen,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.water_drop, color: Colors.white, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$duePlants bitkinin sulama zamanı geldi!',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                itemCount: plantList.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final plant = plantList[index];
                  final lastDate = dates[plant.name];
                  final nextDate = nextWateringDate(plant);
                  final due = isWateringDue(plant);

                  return Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              plant.emoji,
                              style: const TextStyle(fontSize: 38),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    plant.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: primaryGreen,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text('💧 Sulama: ${plant.water}'),
                                  const SizedBox(height: 3),
                                  Text('☀️ Işık: ${plant.sunlight}'),
                                ],
                              ),
                            ),
                            Icon(
                              due
                                  ? Icons.warning_amber_rounded
                                  : Icons.check_circle,
                              color: due ? Colors.orange : Colors.green,
                              size: 27,
                            ),
                          ],
                        ),
                        const Divider(height: 22),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                lastDate == null
                                    ? 'Henüz sulanmadı'
                                    : 'Son sulama: ${formatShortDate(lastDate)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                            Text(
                              due
                                  ? 'Sulama zamanı!'
                                  : 'Sonraki: ${formatShortDate(nextDate!)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: due ? Colors.orange : primaryGreen,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryGreen,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.all(12),
                            ),
                            onPressed: () async {
                              await markPlantAsWatered(plant);

                              if (!context.mounted) return;

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${plant.name} sulandı olarak kaydedildi! 🌱',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.water_drop),
                            label: const Text('Bugün Suladım'),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// Tek bir bitkinin bakım rehberi
class CareGuidePage extends StatelessWidget {
  final Plant plant;

  const CareGuidePage({super.key, required this.plant});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text(
          'Bakım Rehberi',
          style: TextStyle(color: primaryGreen, fontWeight: FontWeight.bold),
        ),
        backgroundColor: backgroundColor,
        iconTheme: const IconThemeData(color: primaryGreen),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              children: [
                Text(plant.emoji, style: const TextStyle(fontSize: 85)),
                const SizedBox(height: 12),
                Text(
                  plant.name,
                  style: const TextStyle(
                    color: primaryGreen,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  plant.category,
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _careInfoCard(
            Icons.water_drop_outlined,
            'Sulama sıklığı',
            plant.water,
          ),
          const SizedBox(height: 12),
          _careInfoCard(
            Icons.wb_sunny_outlined,
            'Işık ihtiyacı',
            plant.sunlight,
          ),
          const SizedBox(height: 12),
          _careInfoCard(
            Icons.info_outline,
            'Bitki hakkında',
            plant.description,
          ),
          const SizedBox(height: 18),
          ValueListenableBuilder<Map<String, DateTime>>(
            valueListenable: lastWateredDates,
            builder: (context, dates, child) {
              final lastDate = dates[plant.name];
              final nextDate = nextWateringDate(plant);
              final due = isWateringDue(plant);

              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sulama Takibi 💧',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: primaryGreen,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      lastDate == null
                          ? 'Henüz sulama kaydı bulunmuyor.'
                          : 'Son sulama: ${formatShortDate(lastDate)}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      nextDate == null
                          ? 'İlk sulama kaydı bekleniyor.'
                          : 'Sonraki sulama: ${formatShortDate(nextDate)}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      due
                          ? 'Sulama zamanı geldi!'
                          : 'Sulama zamanı henüz gelmedi.',
                      style: TextStyle(
                        color: due ? Colors.orange : Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.all(15),
                        ),
                        onPressed: () async {
                          await markPlantAsWatered(plant);

                          if (!context.mounted) return;

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '${plant.name} için sulama tarihi kaydedildi!',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.water_drop),
                        label: const Text('Bugün Suladım'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          const Text(
            'Not: Sulama aralıkları başlangıç önerileridir. Toprak nemini ve bitkinin ortam koşullarını kontrol et.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _careInfoCard(IconData icon, String title, String description) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: primaryGreen, size: 28),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 5),
                Text(description, style: const TextStyle(height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Sepet ekranı
class CartPage extends StatelessWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Plant>>(
      valueListenable: cartItems,
      builder: (context, items, child) {
        if (items.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.shopping_bag_outlined,
                  size: 75,
                  color: primaryGreen,
                ),
                SizedBox(height: 15),
                Text(
                  'Sepetin henüz boş 🌱',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: primaryGreen,
                  ),
                ),
                SizedBox(height: 8),
                Text('Bitkileri keşfetmeye başlayabilirsin.'),
              ],
            ),
          );
        }

        final totalPrice = items.fold<int>(
          0,
          (total, plant) => total + plant.price,
        );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Sepetim 🌿',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: primaryGreen,
                      ),
                    ),
                  ),
                  Text('${items.length} ürün'),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: items.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final plant = items[index];

                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Text(plant.emoji, style: const TextStyle(fontSize: 42)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                plant.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                plant.category,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '${plant.price} TL',
                                style: const TextStyle(
                                  color: primaryGreen,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Sepetten kaldır',
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                          onPressed: () {
                            final updated = [...cartItems.value];
                            updated.removeAt(index);
                            cartItems.value = updated;
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Toplam Tutar',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '$totalPrice TL',
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                          color: primaryGreen,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => CheckoutPage(
                              items: List<Plant>.from(items),
                              totalPrice: totalPrice,
                            ),
                          ),
                        );
                      },
                      child: const Text('Sepeti Onayla'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// Sipariş ekranı
class CheckoutPage extends StatefulWidget {
  final List<Plant> items;
  final int totalPrice;

  const CheckoutPage({
    super.key,
    required this.items,
    required this.totalPrice,
  });

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  void _completeOrder() {
    if (!_formKey.currentState!.validate()) return;

    // Tamamlanan siparişi geçmişe ekle.
    final newOrder = OrderRecord(
      customerName: _nameController.text.trim(),
      phone: _phoneController.text.trim(),
      address: _addressController.text.trim(),
      plantNames: widget.items.map((plant) => plant.name).toList(),
      totalPrice: widget.totalPrice,
      orderDate: DateTime.now(),
    );

    orderHistory.value = [newOrder, ...orderHistory.value];

    // Sipariş tamamlanınca sepeti temizle.
    cartItems.value = [];

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => OrderSuccessPage(
          customerName: _nameController.text.trim(),
          totalPrice: widget.totalPrice,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sipariş Özeti',
          style: TextStyle(color: primaryGreen, fontWeight: FontWeight.bold),
        ),
        backgroundColor: backgroundColor,
        iconTheme: const IconThemeData(color: primaryGreen),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Teslimat Bilgileri',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: primaryGreen,
                ),
              ),
              const SizedBox(height: 16),
              _buildInput(
                controller: _nameController,
                label: 'Ad Soyad',
                icon: Icons.person_outline,
                validatorMessage: 'Lütfen adınızı ve soyadınızı girin.',
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _phoneController,
                label: 'Telefon Numarası',
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                validatorMessage: 'Lütfen telefon numaranızı girin.',
              ),
              const SizedBox(height: 12),
              _buildInput(
                controller: _addressController,
                label: 'Teslimat Adresi',
                icon: Icons.location_on_outlined,
                maxLines: 3,
                validatorMessage: 'Lütfen teslimat adresinizi girin.',
              ),
              const SizedBox(height: 26),
              const Text(
                'Siparişindeki Bitkiler',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: primaryGreen,
                ),
              ),
              const SizedBox(height: 12),
              ...widget.items.map(
                (plant) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Text(plant.emoji, style: const TextStyle(fontSize: 34)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          plant.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        '${plant.price} TL',
                        style: const TextStyle(
                          color: primaryGreen,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Ödenecek Toplam',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      '${widget.totalPrice} TL',
                      style: const TextStyle(
                        color: primaryGreen,
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _completeOrder,
                  child: const Text(
                    'Siparişi Tamamla',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Bu bir demo sipariş ekranıdır. Gerçek ödeme alınmaz.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInput({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String validatorMessage,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: primaryGreen),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return validatorMessage;
        }
        return null;
      },
    );
  }
}

// Sipariş geçmişi ekranı
class OrderHistoryPage extends StatelessWidget {
  const OrderHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text(
          'Sipariş Geçmişim',
          style: TextStyle(color: primaryGreen, fontWeight: FontWeight.bold),
        ),
        backgroundColor: backgroundColor,
        iconTheme: const IconThemeData(color: primaryGreen),
      ),
      body: ValueListenableBuilder<List<OrderRecord>>(
        valueListenable: orderHistory,
        builder: (context, orders, child) {
          if (orders.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 75,
                    color: primaryGreen,
                  ),
                  SizedBox(height: 15),
                  Text(
                    'Henüz siparişin bulunmuyor.',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: primaryGreen,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            itemBuilder: (context, index) {
              final order = orders[index];
              final date = order.orderDate.toLocal();

              final formattedDate =
                  '${date.day.toString().padLeft(2, '0')}.'
                  '${date.month.toString().padLeft(2, '0')}.'
                  '${date.year} '
                  '${date.hour.toString().padLeft(2, '0')}:'
                  '${date.minute.toString().padLeft(2, '0')}';

              return Card(
                color: Colors.white,
                margin: const EdgeInsets.only(bottom: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(17),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.receipt_long, color: primaryGreen),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Sipariş #${orders.length - index}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                                color: primaryGreen,
                              ),
                            ),
                          ),
                          const Icon(Icons.check_circle, color: Colors.green),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('Tarih: $formattedDate'),
                      const Divider(height: 22),
                      const Text(
                        'Sipariş edilen bitkiler:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 7),
                      ...order.plantNames.map(
                        (name) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('🌿 $name'),
                        ),
                      ),
                      const Divider(height: 22),
                      Text('Alıcı: ${order.customerName}'),
                      const SizedBox(height: 5),
                      Text('Telefon: ${order.phone}'),
                      const SizedBox(height: 5),
                      Text('Adres: ${order.address}'),
                      const Divider(height: 22),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Toplam Tutar',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          Text(
                            '${order.totalPrice} TL',
                            style: const TextStyle(
                              color: primaryGreen,
                              fontWeight: FontWeight.bold,
                              fontSize: 19,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// Sipariş başarı ekranı
class OrderSuccessPage extends StatelessWidget {
  final String customerName;
  final int totalPrice;

  const OrderSuccessPage({
    super.key,
    required this.customerName,
    required this.totalPrice,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle, color: primaryGreen, size: 100),
                const SizedBox(height: 22),
                const Text(
                  'Siparişin alındı! 🌱',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: primaryGreen,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Teşekkürler $customerName. Bitkilerini en kısa sürede hazırlayacağız.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, height: 1.5),
                ),
                const SizedBox(height: 18),
                Text(
                  'Sipariş Tutarı: $totalPrice TL',
                  style: const TextStyle(
                    color: primaryGreen,
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const HomeScreen(),
                        ),
                        (route) => false,
                      );
                    },
                    child: const Text('Ana Sayfaya Dön'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

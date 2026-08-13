import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class LocalDbService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  static Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'healthvault.db');

    return await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE,
            password TEXT,
            first_name TEXT,
            last_name TEXT,
            phone_number TEXT,
            aadhaar_number TEXT,
            role TEXT,
            state TEXT,
            profile_image TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE states(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE
          )
        ''');

        await db.execute('''
          CREATE TABLE districts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            state_id INTEGER,
            name TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE taluks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            district_id INTEGER,
            name TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE areas(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            district_id INTEGER,
            taluk_id INTEGER,
            block TEXT,
            village_or_ward TEXT,
            area_type TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE user_areas(
            user_id INTEGER,
            area_id INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE families(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            family_head_name TEXT,
            house_number TEXT,
            contact_number TEXT,
            area_id INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE members(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            family_id INTEGER,
            full_name TEXT,
            age INTEGER,
            gender TEXT,
            relationship_to_head TEXT,
            profile_image TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE medical_records(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            member_id INTEGER,
            recorded_by INTEGER,
            blood_sugar_fasting REAL,
            blood_sugar_postprandial REAL,
            blood_pressure_systolic INTEGER,
            blood_pressure_diastolic INTEGER,
            temperature REAL,
            pulse_rate INTEGER,
            notes TEXT,
            entry_source TEXT,
            device_id TEXT,
            recorded_at TEXT
          )
        ''');

        // Insert Default Master Admin
        await db.insert('users', {
          'username': 'admin',
          'password': 'admin',
          'role': 'superuser',
          'first_name': 'Admin',
          'last_name': 'System',
        });

        await _seedInitialData(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE users ADD COLUMN profile_image TEXT');
          } catch (e) {
            // Ignore if column already exists
          }
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE members ADD COLUMN profile_image TEXT');
          } catch (e) {
            // Ignore if column already exists
          }
        }
        if (oldVersion < 4) {
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS taluks(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                district_id INTEGER,
                name TEXT
              )
            ''');
            await db.execute('ALTER TABLE areas ADD COLUMN taluk_id INTEGER');
          } catch (e) {
            // Ignore if errors occur during column addition
          }
        }
        if (oldVersion < 5) {
          try {
            await db.execute('ALTER TABLE areas ADD COLUMN area_type TEXT');
          } catch (e) {
            // Ignore
          }
          await _seedInitialData(db);
        }
        // Repair/sanitize any legacy oversized base64 images that caused CursorWindow errors
        try {
          await db.execute('UPDATE users SET profile_image = NULL WHERE length(profile_image) > 150000');
        } catch (_) {}
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Seeding Logic (Real Government Data)
  // ─────────────────────────────────────────────────────────────────────────────

  static Future<void> _seedInitialData(Database db) async {
    // 1. Seed State: Karnataka
    int stateId;
    final List<Map<String, dynamic>> existingStates = await db.query('states', where: 'name = ?', whereArgs: ['Karnataka']);
    if (existingStates.isEmpty) {
      stateId = await db.insert('states', {'name': 'Karnataka'});
    } else {
      stateId = existingStates.first['id'] as int;
    }

    // 2. Seed Districts
    // Sources: https://bengaluruurban.nic.in/, https://bengalurural.nic.in/, https://kolar.nic.in/
    final districts = ['Bengaluru Urban', 'Bengaluru Rural', 'Kolar'];
    Map<String, int> districtIds = {};
    for (var dName in districts) {
      final List<Map<String, dynamic>> existing = await db.query('districts', where: 'name = ? AND state_id = ?', whereArgs: [dName, stateId]);
      if (existing.isEmpty) {
        districtIds[dName] = await db.insert('districts', {'state_id': stateId, 'name': dName});
      } else {
        districtIds[dName] = existing.first['id'] as int;
      }
    }

    // 3. Seed Taluks
    final talukData = {
      'Bengaluru Urban': ['Bengaluru North', 'Bengaluru North (Additional)', 'Bengaluru South', 'Bengaluru East', 'Anekal'],
      'Bengaluru Rural': ['Devanahalli', 'Doddaballapura', 'Hosakote', 'Nelamangala'],
      'Kolar': ['Bangarpet', 'KGF', 'Kolar', 'Malur', 'Mulbagal', 'Srinivasapura'],
    };

    Map<String, int> talukIds = {};
    for (var dName in talukData.keys) {
      int dId = districtIds[dName]!;
      final tNames = talukData[dName]!;
      for (var tName in tNames) {
        final List<Map<String, dynamic>> existing = await db.query('taluks', where: 'name = ? AND district_id = ?', whereArgs: [tName, dId]);
        if (existing.isEmpty) {
          talukIds['$dId-$tName'] = await db.insert('taluks', {'district_id': dId, 'name': tName});
        } else {
          talukIds['$dId-$tName'] = existing.first['id'] as int;
        }
      }
    }

    // 4. Seed Verified Areas (Wards, GPs, Localities, Villages)
    // Hierarchy Urban: District -> Taluk -> Urban Ward -> Locality
    // Hierarchy Rural: District -> Taluk -> Gram Panchayat -> Village
    
    final verifiedAreas = [
      // Bengaluru Urban - Bengaluru East - Ward 109 Localities
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'Kundalahalli Colony'},
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'AECS Layout'},
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'Hanuma Reddy Layout'},
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'Channappanahalli'},
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'Lakshminarayanapura'},
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'Ashwath Nagar'},
      {'d': 'Bengaluru Urban', 't': 'Bengaluru East', 'type': 'LOCALITY', 'p': 'Ward 109 — AECS Layout', 'v': 'Hemanth Nagar'},

      // Bengaluru Rural - Devanahalli Gram Panchayats
      {'d': 'Bengaluru Rural', 't': 'Devanahalli', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Kundana'},
      {'d': 'Bengaluru Rural', 't': 'Devanahalli', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Mandibele'},
      {'d': 'Bengaluru Rural', 't': 'Devanahalli', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Koramangala'},

      // Bengaluru Rural - Nelamangala Gram Panchayats
      {'d': 'Bengaluru Rural', 't': 'Nelamangala', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Agalakuppe'},
      {'d': 'Bengaluru Rural', 't': 'Nelamangala', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Arebommanahalli'},
      {'d': 'Bengaluru Rural', 't': 'Nelamangala', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Boodihal'},
      {'d': 'Bengaluru Rural', 't': 'Nelamangala', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Doddabele'},
      {'d': 'Bengaluru Rural', 't': 'Nelamangala', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Gollahalli'},
      {'d': 'Bengaluru Rural', 't': 'Nelamangala', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': 'Hasiruvalli'},

      // Kolar - Kolar Taluk Gram Panchayats (34)
      ...['Ammanallur', 'Annenahalli', 'Arabhikothanur', 'Arahalli', 'Beglihosahalli', 'Belamaranahalli', 'Bellur', 'Channasandra', 'Chowdadenahalli', 'Doddahasala', 'Harati', 'Holur', 'Honnenahalli', 'Huttur', 'Ithrasanahally', 'Jannagatta', 'Kondarajanahalli', 'Kyalanur', 'Madanahalli', 'Madderi', 'Marjenahalli', 'Mudavadi', 'Muduvathi', 'Narasapura', 'Seethi', 'Settihalli', 'Shapuru', 'Soolur', 'Sugatur', 'Thoradevandahalli', 'Thotli', 'Uragali', 'Vadaguru', 'Vokkaleri']
          .map((v) => {'d': 'Kolar', 't': 'Kolar', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': v}),

      // Kolar - Malur Gram Panchayats (28)
      ...['Abbenahalli', 'Araleri', 'Baliganahalli', 'Banahalli', 'Chikkakunthur', 'Chikkathirupathi', 'D.N.Doddi', 'Dinnehalli', 'Doddashivara', 'Hasandahalli', 'Huladenahalli', 'Hulimangala Hosakote', 'Hungenahalli', 'Jayamangala', 'K.G.Halli', 'Kondasettihalli', 'Kudiyanur', 'Lakkur', 'Madivala', 'Masti', 'Nosagere', 'Nutave', 'Rajenahalli', 'Santehalli', 'Shivarapatna', 'Takel', 'Thornahalli', 'Trunasi']
          .map((v) => {'d': 'Kolar', 't': 'Malur', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': v}),

      // Kolar - Bangarpet Gram Panchayats (21)
      ...['Alambadi Jothenahalli', 'Balamande', 'Boodikote', 'Chikka Ankandahalli', 'Chinnakote', 'Dhonimadagu', 'Doddavalagamadi', 'Doddurukarapanahalli', 'Gullahalli', 'Hulibele', 'Hunkunda', 'Iynorahosahalli', 'Kamasamudra', 'Karahalli', 'Kesaranahalli', 'Kethaganahalli', 'Magondi', 'Mavahalli', 'Soolikunte', 'Thoppanahalli', 'Yalesandra']
          .map((v) => {'d': 'Kolar', 't': 'Bangarpet', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': v}),

      // Kolar - KGF Gram Panchayats (16)
      ...['Bethamangala', 'Ghattakamadenahalli', 'Ghattadamadamangala', 'Hulkuru', 'Jakkarasanakuppa', 'Kammasandra', 'Kangandlahalli', 'Kyasamballi', 'Marikuppa', 'N.G.Hulkur', 'Parandahalli', 'Ramasagara', 'Srinivasasandra', 'Sundarapalya', 'T.Gollahalli', 'Vengasandra']
          .map((v) => {'d': 'Kolar', 't': 'KGF', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': v}),

      // Kolar - Mulbagal Gram Panchayats (30)
      ...['Aavani', 'Agara', 'Alangur', 'Ambikallu', 'Angondahalli', 'Balla', 'Byrakur', 'Devarayasamudra', 'Dhulappalli', 'Emmenatha', 'Gudipalli', 'Gummakallu', 'H.Gollahalli', 'Hanumanahalli', 'Hebbani', 'Kappalamadagu', 'Kurudamale', 'Mallanayakanahalli', 'Mothakapalli', 'Mudigere', 'Mudiyanur', 'Mushtur', 'Nangali', 'Pichhaguntlahalli', 'Rajendrahalli', 'Sonnavadi', 'Tayalur', 'Thimmaravutanahalli', 'Urukunte Mittur', 'Uthanur']
          .map((v) => {'d': 'Kolar', 't': 'Mulbagal', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': v}),

      // Kolar - Srinivasapura Gram Panchayats (25)
      ...['Addagal', 'Arikunte', 'Byraganahalli', 'Chaldiganahalli', 'Dalasanur', 'Gownipalli', 'Hodali', 'J.Thimmasandra', 'Kodipalli', 'Kolathur', 'Koorigepalli', 'Lakshmisagara', 'Lakshmipur', 'Mastenahalli', 'Mudimadagu', 'Muthakapalli', 'Nambihalli', 'Nelavanki', 'Pulagurukota', 'Raylapadu', 'Ronur', 'Somayajalapalli', 'Thadigol', 'Yaldur', 'Yarramvaripalli']
          .map((v) => {'d': 'Kolar', 't': 'Srinivasapura', 'type': 'GRAM_PANCHAYAT', 'p': '', 'v': v}),
    ];

    Map<String, int> areaIdsMap = {};
    for (var area in verifiedAreas) {
      int dId = districtIds[area['d']]!;
      int tId = talukIds['$dId-${area['t']}'] ?? 0;
      if (tId == 0) continue;

      final List<Map<String, dynamic>> existing = await db.query('areas', 
          where: 'village_or_ward = ? AND taluk_id = ?', whereArgs: [area['v'], tId]);
      if (existing.isEmpty) {
        areaIdsMap[area['v']!] = await db.insert('areas', {
          'district_id': dId,
          'taluk_id': tId,
          'block': area['p'],
          'village_or_ward': area['v'],
          'area_type': area['type'],
        });
      } else {
        areaIdsMap[area['v']!] = existing.first['id'] as int;
      }
    }

    // 5. Seed Demo ASHA Users (Mapped to Real Locations)
    final demoUsers = [
      {'un': 'asha_001', 'fn': 'Demo ASHA', 'ln': 'Bengaluru', 'ph': '555-0101', 'area': 'Kundalahalli Colony'},
      {'un': 'asha_002', 'fn': 'Demo ASHA', 'ln': 'Bengaluru Rural', 'ph': '555-0202', 'area': 'Kundana'},
      {'un': 'asha_003', 'fn': 'Demo ASHA', 'ln': 'Kolar', 'ph': '555-0303', 'area': 'Masti'},
    ];

    for (var u in demoUsers) {
      final List<Map<String, dynamic>> existing = await db.query('users', where: 'username = ?', whereArgs: [u['un']]);
      int uId;
      if (existing.isEmpty) {
        uId = await db.insert('users', {
          'username': u['un'],
          'password': 'password123',
          'first_name': u['fn'],
          'last_name': u['ln'],
          'phone_number': u['ph'],
          'aadhaar_number': '0000-0000-0000',
          'role': 'asha',
          'state': stateId.toString(),
        });
      } else {
        uId = existing.first['id'] as int;
      }

      // Assign Area
      int aId = areaIdsMap[u['area']] ?? 0;
      if (aId != 0) {
        final List<Map<String, dynamic>> existingAssignment = await db.query('user_areas', 
            where: 'user_id = ? AND area_id = ?', whereArgs: [uId, aId]);
        if (existingAssignment.isEmpty) {
          await db.insert('user_areas', {'user_id': uId, 'area_id': aId});
        }
      }
    }

    // 6. Seed Demo Families (Mapped to Real Locations)
    final demoFamilies = [
      {'name': 'Family 001 (Demo)', 'house': 'H-101', 'area': 'Kundalahalli Colony'},
      {'name': 'Family 002 (Demo)', 'house': 'R-202', 'area': 'Kundana'},
      {'name': 'Family 003 (Demo)', 'house': 'K-303', 'area': 'Masti'},
    ];

    for (var f in demoFamilies) {
      int aId = areaIdsMap[f['area']] ?? 0;
      if (aId == 0) continue;

      final List<Map<String, dynamic>> existing = await db.query('families', 
          where: 'family_head_name = ? AND area_id = ?', whereArgs: [f['name'], aId]);
      if (existing.isEmpty) {
        await db.insert('families', {
          'family_head_name': f['name'],
          'house_number': f['house'],
          'contact_number': '99999-88888',
          'area_id': aId,
        });
      }
    }

    // Clean up old demo data from previous seedings if it exists
    await db.delete('areas', where: "village_or_ward LIKE '%Demo Area A%'");
  }

  // Generate fake local token based on user ID
  static String _generateToken(int userId) {
    return 'local_token_$userId';
  }

  static int _getUserIdFromToken(String token) {
    if (token.startsWith('local_token_')) {
      return int.tryParse(token.split('_').last) ?? 0;
    }
    return 0;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Authentication
  // ─────────────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> loginASHA(String name, String phoneNumber) async {
    final db = await database;
    // Match by: full name (first + last), first name only, OR username (login name)
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      "SELECT * FROM users WHERE (first_name || ' ' || last_name = ? OR first_name = ? OR username = ?) AND phone_number = ? AND role = 'asha'",
      [name, name, name, phoneNumber],
    );
    if (maps.isNotEmpty) {
      final user = maps.first;
      return await _buildUserPayload(user);
    }
    throw Exception('Invalid Name or Phone Number');
  }

  static Future<Map<String, dynamic>> loginAdmin(String username, String password) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'users',
      where: 'username = ? AND password = ?',
      whereArgs: [username, password],
    );
    if (maps.isNotEmpty) {
      final user = maps.first;
      return await _buildUserPayload(user);
    }
    throw Exception('Invalid Admin Username or Password');
  }

  static Future<Map<String, dynamic>> _buildUserPayload(Map<String, dynamic> user) async {
    final db = await database;
    // Fetch assigned areas with their details, district name, taluk name, and area type
    final areaMaps = await db.rawQuery('''
      SELECT a.id, a.block, a.village_or_ward, a.area_type, d.name as district_name, t.name as taluk_name
      FROM areas a 
      JOIN user_areas ua ON a.id = ua.area_id 
      LEFT JOIN districts d ON a.district_id = d.id
      LEFT JOIN taluks t ON a.taluk_id = t.id
      WHERE ua.user_id = ?
      ORDER BY a.village_or_ward ASC
    ''', [user['id']]);
    
    final assignedAreas = areaMaps.map((e) => {
      'id': e['id'],
      'block': e['block'],
      'village_or_ward': e['village_or_ward'],
      'area_type': e['area_type'],
      'district_name': e['district_name'],
      'taluk_name': e['taluk_name'],
    }).toList();

    final districtNames = areaMaps.map((e) => e['district_name']?.toString() ?? 'N/A').toSet().toList();
    final areaNames = areaMaps.map((e) => e['village_or_ward']?.toString() ?? 'Unnamed Area').toList();

    // Fetch state name
    String stateName = 'N/A';
    if (user['state'] != null && user['state'].toString().isNotEmpty) {
      final stateMaps = await db.query('states', where: 'id = ?', whereArgs: [user['state']]);
      if (stateMaps.isNotEmpty) {
        stateName = stateMaps.first['name']?.toString() ?? 'N/A';
      }
    }

    return {
      'token': _generateToken(user['id'] as int),
      'user': {
        'id': user['id'],
        'username': user['username'],
        'first_name': user['first_name'],
        'last_name': user['last_name'],
        'phone_number': user['phone_number'],
        'aadhaar_number': user['aadhaar_number'],
        'profile_image': user['profile_image'],
        'role': user['role'],
        'state_name': stateName,
        'district_names': districtNames,
        'area_names': areaNames,
        'assigned_areas': assignedAreas,
      }
    };
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // ASHA Worker Logic
  // ─────────────────────────────────────────────────────────────────────────────

  static Future<List<dynamic>> getFamilies(String token) async {
    final db = await database;
    final userId = _getUserIdFromToken(token);
    
    // Check if the user is a superuser (admin). If so, return all families.
    final userMaps = await db.query('users', where: 'id = ?', whereArgs: [userId]);
    if (userMaps.isNotEmpty && userMaps.first['role'] == 'superuser') {
      final List<Map<String, dynamic>> maps = await db.query('families', orderBy: 'family_head_name ASC');
      return maps.toList();
    }

    // Otherwise, filter by the worker's assigned areas.
    final areaMaps = await db.query('user_areas', columns: ['area_id'], where: 'user_id = ?', whereArgs: [userId]);
    final areaIds = areaMaps.map((e) => e['area_id'] as int).toList();
    
    if (areaIds.isEmpty) {
      return [];
    }

    final placeholders = List.filled(areaIds.length, '?').join(', ');
    final List<Map<String, dynamic>> maps = await db.query(
      'families',
      where: 'area_id IN ($placeholders)',
      whereArgs: areaIds,
      orderBy: 'family_head_name ASC',
    );
    return maps.toList();
  }

  static Future<bool> addFamily(String token, String headName, String houseNo, String contactNo, String areaId) async {
    final db = await database;
    await db.insert('families', {
      'family_head_name': headName,
      'house_number': houseNo,
      'contact_number': contactNo,
      'area_id': int.parse(areaId),
    });
    return true;
  }

  static Future<List<dynamic>> getMembers(String token) async {
    final db = await database;
    final List<Map<String, dynamic>> members = await db.query('members', orderBy: 'full_name ASC');
    
    // We need to append the latest flag and last_recorded_at
    List<Map<String, dynamic>> result = [];
    for (var m in members) {
      final mCopy = Map<String, dynamic>.from(m);
      mCopy['family'] = m['family_id'];
      
      final records = await db.query(
        'medical_records',
        where: 'member_id = ?',
        whereArgs: [m['id']],
        orderBy: 'recorded_at DESC',
        limit: 1,
      );

      if (records.isNotEmpty) {
        final r = records.first;
        mCopy['last_recorded_at'] = r['recorded_at'];
        mCopy['current_flag'] = _calculateFlag(r);
      } else {
        mCopy['last_recorded_at'] = null;
        mCopy['current_flag'] = null;
      }
      result.add(mCopy);
    }
    return result;
  }

  static Future<bool> addMember(
    String token,
    String familyId,
    String fullName,
    int age,
    String gender,
    String relationship, {
    String? profileImage,
  }) async {
    final db = await database;
    await db.insert('members', {
      'family_id': int.parse(familyId),
      'full_name': fullName,
      'age': age,
      'gender': gender,
      'relationship_to_head': relationship,
      'profile_image': profileImage,
    });
    return true;
  }

  static Future<bool> updateMember({
    required String token,
    required String memberId,
    required String fullName,
    required int age,
    required String gender,
    required String relationship,
    String? profileImage,
  }) async {
    final db = await database;
    final Map<String, dynamic> values = {
      'full_name': fullName,
      'age': age,
      'gender': gender,
      'relationship_to_head': relationship,
    };
    if (profileImage != null) {
      values['profile_image'] = profileImage;
    }
    await db.update('members', values, where: 'id = ?', whereArgs: [int.parse(memberId)]);
    return true;
  }

  static Future<List<dynamic>> getMemberHistory(String token, String memberId) async {
    final db = await database;
    final records = await db.query(
      'medical_records',
      where: 'member_id = ?',
      whereArgs: [int.parse(memberId)],
      orderBy: 'recorded_at DESC',
    );

    List<Map<String, dynamic>> result = [];
    for (var r in records) {
      final rCopy = Map<String, dynamic>.from(r);
      rCopy['flag'] = _calculateFlag(r);
      
      // Get recorded by name
      final users = await db.query('users', where: 'id = ?', whereArgs: [r['recorded_by']]);
      if (users.isNotEmpty) {
        final u = users.first;
        rCopy['recorded_by_name'] = '${u['first_name']} ${u['last_name']}';
        rCopy['recorded_by_role'] = u['role'];
      }
      
      result.add(rCopy);
    }
    return result;
  }

  static Future<Map<String, dynamic>> getMemberAnalytics(String token, String memberId) async {
    final db = await database;
    final records = await db.query(
      'medical_records',
      where: 'member_id = ?',
      whereArgs: [int.parse(memberId)],
      orderBy: 'recorded_at ASC',
    );

    List<Map<String, dynamic>> sys = [];
    List<Map<String, dynamic>> dia = [];
    List<Map<String, dynamic>> bsf = [];

    for (var r in records) {
      final date = r['recorded_at'] as String;
      if (r['blood_pressure_systolic'] != null) {
        sys.add({'date': date, 'value': r['blood_pressure_systolic']});
      }
      if (r['blood_pressure_diastolic'] != null) {
        dia.add({'date': date, 'value': r['blood_pressure_diastolic']});
      }
      if (r['blood_sugar_fasting'] != null) {
        bsf.add({'date': date, 'value': r['blood_sugar_fasting']});
      }
    }

    return {
      'blood_pressure_systolic': sys,
      'blood_pressure_diastolic': dia,
      'blood_sugar_fasting': bsf,
    };
  }

  static Future<bool> addMedicalRecord({
    required String token,
    required String memberId,
    double? bloodSugarFasting,
    double? bloodSugarPostprandial,
    int? bloodPressureSystolic,
    int? bloodPressureDiastolic,
    double? temperature,
    int? pulseRate,
    String? notes,
    String entrySource = 'manual',
    String? deviceId,
  }) async {
    final db = await database;
    final userId = _getUserIdFromToken(token);
    await db.insert('medical_records', {
      'member_id': int.parse(memberId),
      'recorded_by': userId,
      'blood_sugar_fasting': bloodSugarFasting,
      'blood_sugar_postprandial': bloodSugarPostprandial,
      'blood_pressure_systolic': bloodPressureSystolic,
      'blood_pressure_diastolic': bloodPressureDiastolic,
      'temperature': temperature,
      'pulse_rate': pulseRate,
      'notes': notes,
      'entry_source': entrySource,
      'device_id': deviceId,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
    });
    return true;
  }

  static String _calculateFlag(Map<String, dynamic> r) {
    bool isCritical = false;
    bool isWarning = false;

    final bps = r['blood_pressure_systolic'] as num?;
    final bpd = r['blood_pressure_diastolic'] as num?;
    if (bps != null || bpd != null) {
      if ((bps != null && bps > 160) || (bpd != null && bpd > 100)) {
        isCritical = true;
      } else if ((bps != null && bps > 140) || (bpd != null && bpd > 90)) {
        isWarning = true;
      }
    }

    final bsf = r['blood_sugar_fasting'] as num?;
    if (bsf != null) {
      if (bsf > 200) {
        isCritical = true;
      } else if (bsf > 126) {
        isWarning = true;
      }
    }

    final temp = r['temperature'] as num?;
    if (temp != null) {
      if (temp > 103) {
        isCritical = true;
      } else if (temp > 100.4) {
        isWarning = true;
      }
    }

    if (isCritical) return 'critical';
    if (isWarning) return 'warning';
    return 'normal';
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Admin Dashboard Logic
  // ─────────────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getDashboardSummary(String token) async {
    final db = await database;
    final familyCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM families')) ?? 0;
    final memberCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM members')) ?? 0;
    
    int highRisk = 0;
    final members = await db.query('members');
    for (var m in members) {
      final records = await db.query(
        'medical_records',
        where: 'member_id = ?',
        whereArgs: [m['id']],
        orderBy: 'recorded_at DESC',
        limit: 1,
      );
      if (records.isNotEmpty) {
        final flag = _calculateFlag(records.first);
        if (flag == 'critical') highRisk++;
      }
    }

    return {
      'total_families': familyCount,
      'total_members': memberCount,
      'high_risk_members': highRisk,
      'active_workers': 0, // Placeholder
    };
  }

  static Future<List<dynamic>> getStates(String token) async {
    final db = await database;
    return await db.query('states', orderBy: 'name ASC');
  }

  static Future<List<dynamic>> getDistricts(String token) async {
    final db = await database;
    return await db.query('districts', orderBy: 'name ASC');
  }

  static Future<List<dynamic>> getTaluks(String token) async {
    final db = await database;
    return await db.query('taluks', orderBy: 'name ASC');
  }

  static Future<List<dynamic>> getAreas(String token) async {
    final db = await database;
    return await db.query('areas', orderBy: 'block ASC, village_or_ward ASC');
  }

  static Future<bool> addState(String token, String name) async {
    final db = await database;
    await db.insert('states', {'name': name});
    return true;
  }

  static Future<bool> addDistrict(String token, String stateId, String name) async {
    final db = await database;
    await db.insert('districts', {'state_id': int.parse(stateId), 'name': name});
    return true;
  }

  static Future<bool> addTaluk(String token, String districtId, String name) async {
    final db = await database;
    await db.insert('taluks', {'district_id': int.parse(districtId), 'name': name});
    return true;
  }

  static Future<bool> addArea(String token, String districtId, String talukId, String block, String villageOrWard, String type) async {
    final db = await database;
    await db.insert('areas', {
      'district_id': int.parse(districtId),
      'taluk_id': int.parse(talukId),
      'block': block,
      'village_or_ward': villageOrWard,
      'area_type': type,
    });
    return true;
  }

  static Future<bool> editState(String token, String stateId, String name) async {
    final db = await database;
    await db.update('states', {'name': name}, where: 'id = ?', whereArgs: [int.parse(stateId)]);
    return true;
  }

  static Future<bool> editDistrict(String token, String districtId, String stateId, String name) async {
    final db = await database;
    await db.update('districts', {'state_id': int.parse(stateId), 'name': name}, where: 'id = ?', whereArgs: [int.parse(districtId)]);
    return true;
  }

  static Future<bool> editTaluk(String token, String talukId, String districtId, String name) async {
    final db = await database;
    await db.update('taluks', {'district_id': int.parse(districtId), 'name': name}, where: 'id = ?', whereArgs: [int.parse(talukId)]);
    return true;
  }

  static Future<bool> editArea(String token, String areaId, String districtId, String talukId, String block, String villageOrWard, String type) async {
    final db = await database;
    await db.update('areas', {
      'district_id': int.parse(districtId),
      'taluk_id': int.parse(talukId),
      'block': block,
      'village_or_ward': villageOrWard,
      'area_type': type,
    }, where: 'id = ?', whereArgs: [int.parse(areaId)]);
    return true;
  }

  static Future<bool> deleteState(String token, String stateId) async {
    final db = await database;
    await db.delete('states', where: 'id = ?', whereArgs: [int.parse(stateId)]);
    return true;
  }

  static Future<bool> deleteDistrict(String token, String districtId) async {
    final db = await database;
    await db.delete('districts', where: 'id = ?', whereArgs: [int.parse(districtId)]);
    return true;
  }

  static Future<bool> deleteTaluk(String token, String talukId) async {
    final db = await database;
    await db.delete('taluks', where: 'id = ?', whereArgs: [int.parse(talukId)]);
    return true;
  }

  static Future<bool> deleteArea(String token, String areaId) async {
    final db = await database;
    await db.delete('areas', where: 'id = ?', whereArgs: [int.parse(areaId)]);
    return true;
  }

  static Future<List<dynamic>> getASHAWorkers(String token) async {
    final db = await database;
    final workers = await db.query('users', where: 'role = ?', whereArgs: ['asha'], orderBy: 'first_name ASC, last_name ASC');
    
    List<Map<String, dynamic>> result = [];
    for (var w in workers) {
      final areaMaps = await db.rawQuery('''
        SELECT a.id, a.village_or_ward 
        FROM areas a 
        JOIN user_areas ua ON a.id = ua.area_id 
        WHERE ua.user_id = ?
      ''', [w['id']]);
      final areaNames = areaMaps.map((e) => e['village_or_ward']?.toString() ?? 'Unnamed Area').toList();
      final areaIds = areaMaps.map((e) => e['id'] as int).toList();

      String stateName = 'N/A';
      if (w['state'] != null && w['state'].toString().isNotEmpty) {
        final stateMaps = await db.query('states', where: 'id = ?', whereArgs: [w['state']]);
        if (stateMaps.isNotEmpty) {
          stateName = stateMaps.first['name']?.toString() ?? 'N/A';
        }
      }

      final wCopy = Map<String, dynamic>.from(w);
      wCopy['state_name'] = stateName;
      wCopy['area_names'] = areaNames;
      wCopy['assigned_areas'] = areaIds;
      result.add(wCopy);
    }
    return result;
  }

  static Future<bool> addASHAWorker({
    required String token,
    required String username,
    required String firstName,
    required String lastName,
    required String phoneNumber,
    required String aadhaarNumber,
    required String stateId,
    required List<String> areaIds,
    String? profileImage,
  }) async {
    final db = await database;
    final userId = await db.insert('users', {
      'username': username,
      'password': 'password123', // Hardcoded default password for created workers
      'first_name': firstName,
      'last_name': lastName,
      'phone_number': phoneNumber,
      'aadhaar_number': aadhaarNumber,
      'state': stateId,
      'role': 'asha',
      'profile_image': profileImage,
    });

    for (var areaId in areaIds) {
      await db.insert('user_areas', {
        'user_id': userId,
        'area_id': int.parse(areaId),
      });
    }
    return true;
  }

  static Future<bool> editASHAWorker({
    required String token,
    required String userId,
    required String username,
    required String firstName,
    required String lastName,
    required String phoneNumber,
    required String aadhaarNumber,
    required String stateId,
    required List<String> areaIds,
    String? profileImage,
  }) async {
    final db = await database;
    final uId = int.parse(userId);
    await db.update('users', {
      'username': username,
      'first_name': firstName,
      'last_name': lastName,
      'phone_number': phoneNumber,
      'aadhaar_number': aadhaarNumber,
      'state': stateId,
      'profile_image': profileImage,
    }, where: 'id = ?', whereArgs: [uId]);

    // Update areas
    await db.delete('user_areas', where: 'user_id = ?', whereArgs: [uId]);
    for (var areaId in areaIds) {
      await db.insert('user_areas', {
        'user_id': uId,
        'area_id': int.parse(areaId),
      });
    }
    return true;
  }

  static Future<bool> deleteASHAWorker(String token, String userId) async {
    final db = await database;
    final uId = int.parse(userId);
    await db.delete('users', where: 'id = ?', whereArgs: [uId]);
    await db.delete('user_areas', where: 'user_id = ?', whereArgs: [uId]);
    return true;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Export Logic
  // ─────────────────────────────────────────────────────────────────────────────

  static Future<Map<String, List<Map<String, dynamic>>>> getExportData(int userId) async {
    final db = await database;

    // 1. Fetch User Profile & Aggregated Geography
    final userList = await db.rawQuery('''
      SELECT u.username, u.first_name, u.last_name, u.phone_number, u.aadhaar_number, 
             s.name as state_name,
             GROUP_CONCAT(DISTINCT d.name) as district_names,
             GROUP_CONCAT(DISTINCT t.name) as taluk_names,
             GROUP_CONCAT(DISTINCT a.village_or_ward) as area_names
      FROM users u
      LEFT JOIN states s ON u.state = s.id
      LEFT JOIN user_areas ua ON u.id = ua.user_id
      LEFT JOIN areas a ON ua.area_id = a.id
      LEFT JOIN taluks t ON a.taluk_id = t.id
      LEFT JOIN districts d ON a.district_id = d.id
      WHERE u.id = ?
      GROUP BY u.id
    ''', [userId]);
    
    // 2. Fetch Authorized Families with full geography
    final families = await db.rawQuery('''
      SELECT f.id, s.name as state_name, d.name as district_name, t.name as taluk_name, 
             a.village_or_ward as area_name, a.area_type, f.family_head_name, f.house_number, f.contact_number
      FROM families f
      JOIN areas a ON f.area_id = a.id
      JOIN taluks t ON a.taluk_id = t.id
      JOIN districts d ON a.district_id = d.id
      JOIN states s ON d.state_id = s.id
      WHERE f.area_id IN (SELECT area_id FROM user_areas WHERE user_id = ?)
      ORDER BY s.name ASC, d.name ASC, t.name ASC, a.village_or_ward ASC, f.family_head_name ASC
    ''', [userId]);

    // 3. Fetch Members with Family Head
    final members = await db.rawQuery('''
      SELECT f.id as family_id, f.family_head_name, m.id as member_id, m.full_name as member_name, 
             m.age, m.gender, m.relationship_to_head
      FROM members m
      JOIN families f ON m.family_id = f.id
      WHERE f.area_id IN (SELECT area_id FROM user_areas WHERE user_id = ?)
      ORDER BY f.family_head_name ASC, m.full_name ASC
    ''', [userId]);

    // 4. Fetch Medical Records with Family & Member details
    final records = await db.rawQuery('''
      SELECT f.id as family_id, f.family_head_name, m.id as member_id, m.full_name as member_name, 
             r.id as record_id, r.recorded_at, r.blood_pressure_systolic, r.blood_pressure_diastolic, 
             r.blood_sugar_fasting, r.blood_sugar_postprandial, r.temperature, r.pulse_rate, 
             r.entry_source, r.notes
      FROM medical_records r
      JOIN members m ON r.member_id = m.id
      JOIN families f ON m.family_id = f.id
      WHERE f.area_id IN (SELECT area_id FROM user_areas WHERE user_id = ?)
      ORDER BY r.recorded_at DESC
    ''', [userId]);

    return {
      'profile': userList.map((e) => Map<String, dynamic>.from(e)).toList(),
      'families': families.map((e) => Map<String, dynamic>.from(e)).toList(),
      'members': members.map((e) => Map<String, dynamic>.from(e)).toList(),
      'records': records.map((e) => Map<String, dynamic>.from(e)).toList(),
    };
  }
}

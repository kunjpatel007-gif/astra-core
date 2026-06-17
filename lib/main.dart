import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class CelestialObject {
  final String name;
  final String type;
  final String constellation;
  final double ra;
  final double dec;
  final double magnitude;
  final String description;
  final String distance;
  final String size;
  final String bestSeason;

  const CelestialObject({
    required this.name,
    required this.type,
    required this.constellation,
    required this.ra,
    required this.dec,
    required this.magnitude,
    required this.description,
    required this.distance,
    required this.size,
    required this.bestSeason,
  });
}

class ObservationLog {
  final int id;
  final String targetName;
  final String objectType;
  final String constellation;
  final int bortleClass;
  final double exposureSeconds;
  final double focalLength;
  final int iso;
  final double skyClarity;
  final String moonPhase;
  final double altitude;
  final double azimuth;
  final String notes;
  final String gearLoadout;
  final DateTime observedAt;

  ObservationLog({
    required this.id,
    required this.targetName,
    required this.objectType,
    required this.constellation,
    required this.bortleClass,
    required this.exposureSeconds,
    required this.focalLength,
    required this.iso,
    required this.skyClarity,
    required this.moonPhase,
    required this.altitude,
    required this.azimuth,
    required this.notes,
    required this.gearLoadout,
    required this.observedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetName': targetName,
    'objectType': objectType,
    'constellation': constellation,
    'bortleClass': bortleClass,
    'exposureSeconds': exposureSeconds,
    'focalLength': focalLength,
    'iso': iso,
    'skyClarity': skyClarity,
    'moonPhase': moonPhase,
    'altitude': altitude,
    'azimuth': azimuth,
    'notes': notes,
    'gearLoadout': gearLoadout,
    'observedAt': observedAt.toIso8601String(),
  };

  factory ObservationLog.fromJson(Map<String, dynamic> j) => ObservationLog(
    id: (j['id'] as int?) ?? 0,
    targetName: j['targetName'] as String,
    objectType: j['objectType'] as String,
    constellation: j['constellation'] as String? ?? 'Unknown',
    bortleClass: j['bortleClass'] as int,
    exposureSeconds: (j['exposureSeconds'] as num).toDouble(),
    focalLength: (j['focalLength'] as num?)?.toDouble() ?? 50.0,
    iso: j['iso'] as int? ?? 1600,
    skyClarity: (j['skyClarity'] as num?)?.toDouble() ?? 75.0,
    moonPhase: j['moonPhase'] as String? ?? 'New Moon',
    altitude: (j['altitude'] as num?)?.toDouble() ?? 45.0,
    azimuth: (j['azimuth'] as num?)?.toDouble() ?? 180.0,
    notes: j['notes'] as String? ?? '',
    gearLoadout: j['gearLoadout'] as String? ?? 'Standard Kit',
    observedAt: j['observedAt'] != null
        ? DateTime.parse(j['observedAt'] as String)
        : DateTime.now(),
  );
}

class LiveSkyService {
  static Future<Map<String, dynamic>> fetchSkyConditions() async {
    final result = <String, dynamic>{
      'moonPhase': _computeMoonPhase(),
      'moonIllumination': _computeMoonIllumination(),
      'skyClarity': 75.0,
      'humidity': 50,
      'seeing': '3.0',
      'location': 'Scanning Space...',
      'lat': 12.9716,
      'lon': 77.5946,
    };

    try {
      final locUri = Uri.parse('https://ipapi.co/json/');
      final locResp = await http
          .get(locUri)
          .timeout(const Duration(seconds: 6));

      if (locResp.statusCode == 200) {
        final locData = jsonDecode(locResp.body);
        result['location'] =
            '${locData['city'] ?? 'Unknown City'}, ${locData['country_code'] ?? 'IN'}';
        result['lat'] = locData['latitude'] ?? result['lat'];
        result['lon'] = locData['longitude'] ?? result['lon'];
      }
    } catch (e) {
      print("🔴 LOCATION API ERROR: $e");
      result['location'] = 'Bengaluru, IN (Local Fallback)';
    }

    try {
      final weatherUri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${result['lat']}&longitude=${result['lon']}&current=cloud_cover,relative_humidity_2m,wind_speed_10m',
      );
      final weatherResp = await http
          .get(weatherUri)
          .timeout(const Duration(seconds: 6));

      if (weatherResp.statusCode == 200) {
        final wData = jsonDecode(weatherResp.body);
        result['skyClarity'] =
            100.0 - (wData['current']['cloud_cover'] as num).toDouble();
        result['humidity'] = (wData['current']['relative_humidity_2m'] as num)
            .toInt();
        result['windSpeed'] = (wData['current']['wind_speed_10m'] as num)
            .toInt();
      }
    } catch (e) {
      print("🔴 WEATHER API ERROR: $e");
    }

    return result;
  }

  static Future<List<Map<String, dynamic>>> fetchVisiblePlanets() async {
    final List<Map<String, dynamic>> planets = [];
    try {
      final uri = Uri.parse(
        'https://api.le-systeme-solaire.net/rest/bodies?filter[]=isPlanet,eq,true',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final bodies = data['bodies'] as List;

        for (var b in bodies) {
          if (b['englishName'] == 'Earth') continue;
          planets.add({
            'name': b['englishName'] ?? 'Unknown',
            'type': 'Planet',
            'constellation': _planetConstellation(
              b['englishName'].toString().toLowerCase(),
            ),
            'magnitude': _approxMagnitude(
              b['englishName'].toString().toLowerCase(),
            ),
            'distance': b['semimajorAxis'] != null
                ? '${(b['semimajorAxis'] / 149597870.7).toStringAsFixed(2)} AU'
                : 'Unknown',
            'gravity': b['gravity'],
            'sideralOrbit': b['sideralOrbit'],
            'avgTemp': b['avgTemp'],
          });
        }
      }
    } catch (e) {
      print("🔴 PLANET API ERROR: $e");
    }

    if (planets.isEmpty) return _fallbackPlanets();
    return planets;
  }

  static Future<List<Map<String, dynamic>>> fetchDeepSkyObjects() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return _embeddedDSOCatalogue();
  }

  static String _computeMoonPhase() {
    final now = DateTime.now();
    final jd = _julianDate(now);
    final phase = ((jd - 2451549.5) / 29.53058770576) % 1.0;
    if (phase < 0.0625) return 'New Moon';
    if (phase < 0.1875) return 'Waxing Crescent';
    if (phase < 0.3125) return 'First Quarter';
    if (phase < 0.4375) return 'Waxing Gibbous';
    if (phase < 0.5625) return 'Full Moon';
    if (phase < 0.6875) return 'Waning Gibbous';
    if (phase < 0.8125) return 'Last Quarter';
    if (phase < 0.9375) return 'Waning Crescent';
    return 'New Moon';
  }

  static String _computeMoonIllumination() {
    final now = DateTime.now();
    final jd = _julianDate(now);
    final phase = ((jd - 2451549.5) / 29.53058770576) % 1.0;
    final illum = (1 - cos(2 * pi * phase)) / 2 * 100;
    return '${illum.toStringAsFixed(0)}%';
  }

  static double _julianDate(DateTime dt) {
    final a = (14 - dt.month) ~/ 12;
    final y = dt.year + 4800 - a;
    final m = dt.month + 12 * a - 3;
    return dt.day +
        (153 * m + 2) ~/ 5 +
        365 * y +
        y ~/ 4 -
        y ~/ 100 +
        y ~/ 400 -
        32045 +
        (dt.hour - 12) / 24.0 +
        dt.minute / 1440.0 +
        dt.second / 86400.0;
  }

  static Future<List<Map<String, dynamic>>> fetchDSOFromAsset() async {
    try {
      final raw = await rootBundle.loadString('assets/celestial_objects.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final objects = data['objects'] as List;

      return objects.map((o) {
        final m = o as Map<String, dynamic>;

        bool isNakedEye = false;
        if (m['naked_eye'] is bool) {
          isNakedEye = m['naked_eye'] as bool;
        } else if (m['naked_eye'] is String) {
          final strVal = (m['naked_eye'] as String).trim().toLowerCase();
          isNakedEye = strVal.isNotEmpty && strVal != 'false';
        }
        final catalogIds = (m['catalog_ids'] as List?)
            ?.map((e) => e.toString())
            .join(' · ');

        return {
          'name': m['name'] as String? ?? 'Unknown',
          'type': m['type'] as String? ?? 'Unknown',
          'subType': m['sub_type']?.toString(),
          'constellation': m['constellation'] as String? ?? 'Unknown',
          'ra': (m['ra_decimal'] as num?)?.toDouble() ?? 0.0,
          'dec': (m['dec_decimal'] as num?)?.toDouble() ?? 0.0,
          'magnitude': (m['magnitude'] as num?)?.toDouble() ?? 99.0,
          'surfaceBrightness': m['surface_brightness']?.toString(),
          'distance': m['distance']?.toString() ?? 'Unknown',
          'size': m['size_arcmin']?.toString(),
          'description': m['description'] as String? ?? '',
          'bestSeason': m['best_season']?.toString(),
          'findingMethod': m['finding_method']?.toString(),
          'nakedEye': isNakedEye,
          'binoculars': m['binoculars']?.toString(),
          'telescope4in': m['telescope_4inch']?.toString(),
          'telescope8in': m['telescope_8inch']?.toString(),
          'telescope12in': m['telescope_12inch']?.toString(),
          'bestMagnification': m['best_magnification']?.toString(),
          'recommendedFilter': m['recommended_filter']?.toString(),
          'minAltitude': (m['min_altitude_deg'] as num?)?.toDouble(),
          'bestSeeing': m['best_seeing_required']?.toString(),
          'imagingExposure': m['imaging_exposure']?.toString(),
          'imagingNotes': m['imaging_notes']?.toString(),
          'difficulty': m['difficulty']?.toString(),
          'nearbyObjects': (m['nearby_objects'] as List?)
              ?.map((e) => e.toString())
              .toList(),
          'catalogIds': catalogIds,
          'avoidMoonPhase': m['avoid_moon_phase']?.toString(),
          'bestAltitude': m['best_altitude']?.toString(),
        };
      }).toList();
    } catch (e) {
      print('🔴 ASSET CATALOGUE ERROR: $e');
      return _embeddedDSOCatalogue();
    }
  }

  static String _planetConstellation(String p) {
    const map = {
      'mercury': 'Gemini',
      'venus': 'Taurus',
      'mars': 'Aries',
      'jupiter': 'Pisces',
      'saturn': 'Aquarius',
      'uranus': 'Aries',
      'neptune': 'Pisces',
    };
    return map[p] ?? 'Tracking';
  }

  static double _approxMagnitude(String p) {
    const map = {
      'mercury': -1.2,
      'venus': -4.5,
      'mars': -2.0,
      'jupiter': -2.7,
      'saturn': 0.6,
      'uranus': 5.7,
      'neptune': 7.8,
    };
    return map[p] ?? 5.0;
  }

  static List<Map<String, dynamic>> _fallbackPlanets() => [
    {
      'name': 'Venus',
      'type': 'Planet',
      'constellation': 'Taurus',
      'magnitude': -4.5,
      'gravity': 8.87,
      'avgTemp': 737,
      'distance': '0.72 AU',
      'sideralOrbit': 224.7,
    },
    {
      'name': 'Mars',
      'type': 'Planet',
      'constellation': 'Aries',
      'magnitude': -2.0,
      'gravity': 3.72,
      'avgTemp': 210,
      'distance': '1.52 AU',
      'sideralOrbit': 686.97,
    },
    {
      'name': 'Jupiter',
      'type': 'Planet',
      'constellation': 'Pisces',
      'magnitude': -2.7,
      'gravity': 24.79,
      'avgTemp': 165,
      'distance': '5.20 AU',
      'sideralOrbit': 4332.59,
    },
    {
      'name': 'Saturn',
      'type': 'Planet',
      'constellation': 'Aquarius',
      'magnitude': 0.6,
      'gravity': 10.44,
      'avgTemp': 134,
      'distance': '9.58 AU',
      'sideralOrbit': 10759.22,
    },
  ];

  static List<Map<String, dynamic>> _embeddedDSOCatalogue() => [
    {
      'name': 'Orion Nebula',
      'type': 'Nebula',
      'constellation': 'Orion',
      'ra': 5.58,
      'dec': -5.39,
      'magnitude': 4.0,
      'distance': '1,344 ly',
      'size': '65×60 arcmin',
      'description':
          'Stellar nursery in Orion\'s sword. One of the brightest nebulae visible to the naked eye.',
      'bestSeason': 'Winter',
    },
    {
      'name': 'Andromeda Galaxy',
      'type': 'Galaxy',
      'constellation': 'Andromeda',
      'ra': 0.71,
      'dec': 41.27,
      'magnitude': 3.44,
      'distance': '2.537 Mly',
      'size': '190×60 arcmin',
      'description':
          'Nearest large galaxy to the Milky Way. Contains ~1 trillion stars.',
      'bestSeason': 'Autumn',
    },
    {
      'name': 'Pleiades',
      'type': 'Star Cluster',
      'constellation': 'Taurus',
      'ra': 3.79,
      'dec': 24.11,
      'magnitude': 1.6,
      'distance': '444 ly',
      'size': '110 arcmin',
      'description':
          'The Seven Sisters open cluster. Dominated by hot blue luminous stars.',
      'bestSeason': 'Winter',
    },
    {
      'name': 'Crab Nebula',
      'type': 'Supernova Remnant',
      'constellation': 'Taurus',
      'ra': 5.58,
      'dec': 22.02,
      'magnitude': 8.4,
      'distance': '6,500 ly',
      'size': '7×5 arcmin',
      'description':
          'Remnant of SN 1054 supernova. Powered by Crab Pulsar spinning 30× per second.',
      'bestSeason': 'Winter',
    },
    {
      'name': 'Whirlpool Galaxy',
      'type': 'Galaxy',
      'constellation': 'Canes Venatici',
      'ra': 13.5,
      'dec': 47.19,
      'magnitude': 8.4,
      'distance': '23 Mly',
      'size': '11×7 arcmin',
      'description': 'Grand design spiral interacting with companion NGC 5195.',
      'bestSeason': 'Spring',
    },
    {
      'name': 'Ring Nebula',
      'type': 'Nebula',
      'constellation': 'Lyra',
      'ra': 18.89,
      'dec': 33.03,
      'magnitude': 8.8,
      'distance': '2,283 ly',
      'size': '1×1 arcmin',
      'description':
          'Iconic planetary nebula formed from a Sun-like star ejecting outer layers.',
      'bestSeason': 'Summer',
    },
  ];
  static Future<List<Map<String, dynamic>>> fetchExtendedDSOCatalogue() async {
    const url =
        'https://simbad.cds.unistra.fr/simbad/sim-tap/sync?REQUEST=doQuery&LANG=ADQL&FORMAT=json&QUERY='
        'SELECT+TOP+80+main_id,otype_txt,ra,dec,flux_V,mespos.bibcode+'
        'FROM+basic+JOIN+flux+ON+basic.oid=flux.oidref+'
        'WHERE+otype_txt+IN+(\'GlCl\',\'OpCl\',\'GNe\',\'RNe\',\'SNR\',\'PartofG\',\'Galaxy\',\'PN\',\'HII\',\'Neb\')+'
        'AND+flux_V+IS+NOT+NULL+AND+flux_V+<+10.0+'
        'ORDER+BY+flux_V+ASC';

    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final rows = data['data'] as List;
        final cols = data['metadata'] as List;

        final idxName = cols.indexWhere((c) => c['name'] == 'main_id');
        final idxType = cols.indexWhere((c) => c['name'] == 'otype_txt');
        final idxRa = cols.indexWhere((c) => c['name'] == 'ra');
        final idxDec = cols.indexWhere((c) => c['name'] == 'dec');
        final idxMag = cols.indexWhere((c) => c['name'] == 'flux_V');

        return rows.map((r) {
          final simbadType = r[idxType] as String? ?? 'Unknown';
          return {
            'name': (r[idxName] as String? ?? 'Unknown').trim(),
            'type': _mapSimbadType(simbadType),
            'simbadType': simbadType,
            'constellation': _constellationFromRaDec(
              (r[idxRa] as num?)?.toDouble() ?? 0,
              (r[idxDec] as num?)?.toDouble() ?? 0,
            ),
            'ra': (r[idxRa] as num?)?.toDouble() ?? 0.0,
            'dec': (r[idxDec] as num?)?.toDouble() ?? 0.0,
            'magnitude': (r[idxMag] as num?)?.toDouble() ?? 99.0,
            'distance': 'See Simbad',
            'description':
                '$simbadType at RA ${(r[idxRa] as num?)?.toStringAsFixed(2)}° '
                'Dec ${(r[idxDec] as num?)?.toStringAsFixed(2)}°',
          };
        }).toList();
      }
    } catch (e) {
      print('🔴 SIMBAD ERROR: $e');
    }
    return _embeddedDSOCatalogue();
  }

  static String _mapSimbadType(String t) {
    if (t.contains('Galaxy') || t == 'PartofG') return 'Galaxy';
    if (t == 'GlCl') return 'Star Cluster';
    if (t == 'OpCl') return 'Star Cluster';
    if (t == 'PN') return 'Nebula';
    if (t == 'GNe' || t == 'RNe' || t == 'HII' || t == 'Neb') return 'Nebula';
    if (t == 'SNR') return 'Supernova Remnant';
    return 'Unknown';
  }

  static String _constellationFromRaDec(double ra, double dec) {
    final raH = ra / 15.0;
    if (dec > 60) return 'Ursa Major';
    if (raH >= 5.0 && raH < 6.5 && dec > -10) return 'Orion';
    if (raH >= 6.5 && raH < 8.0 && dec > 15) return 'Gemini';
    if (raH >= 3.5 && raH < 5.0 && dec > 15) return 'Taurus';
    if (raH >= 0.5 && raH < 2.0 && dec > 30) return 'Andromeda';
    if (raH >= 12.0 && raH < 14.5 && dec > 20) return 'Canes Venatici';
    if (raH >= 18.0 && raH < 20.0 && dec > 25) return 'Lyra';
    if (raH >= 20.0 && raH < 22.0 && dec > 30) return 'Cygnus';
    if (raH >= 22.0 && raH < 24.0 && dec > 50) return 'Cassiopeia';
    if (raH >= 10.0 && raH < 12.0 && dec > 10) return 'Leo';
    if (raH >= 16.0 && raH < 18.0 && dec < -15) return 'Scorpius';
    if (raH >= 18.0 && raH < 20.0 && dec < 0) return 'Sagittarius';
    return 'Unknown';
  }

  static Future<List<Map<String, dynamic>>> fetchPlanetPositions() async {
    final today = DateTime.now();
    final dateStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final tomorrow =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${(today.day + 1).toString().padLeft(2, '0')}';

    const planetIds = {
      'Mercury': '199',
      'Venus': '299',
      'Mars': '499',
      'Jupiter': '599',
      'Saturn': '699',
      'Uranus': '799',
      'Neptune': '899',
    };

    final List<Map<String, dynamic>> results = [];

    for (final entry in planetIds.entries) {
      try {
        final uri = Uri.parse(
          'https://ssd.jpl.nasa.gov/api/horizons.api'
          '?format=json'
          '&COMMAND=%27${entry.value}%27'
          '&OBJ_DATA=NO'
          '&MAKE_EPHEM=YES'
          '&EPHEM_TYPE=OBSERVER'
          '&CENTER=%27500%40399%27'
          '&START_TIME=%27$dateStr%27'
          '&STOP_TIME=%27$tomorrow%27'
          '&STEP_SIZE=%271+d%27'
          '&QUANTITIES=%271,9,20%27',
        );

        final resp = await http.get(uri).timeout(const Duration(seconds: 8));

        if (resp.statusCode == 200) {
          final raw = jsonDecode(resp.body)['result'] as String;
          final parsed = _parseHorizonsEphemeris(raw, entry.key);
          if (parsed != null) results.add(parsed);
        }
      } catch (e) {
        print('🔴 HORIZONS ${entry.key} ERROR: $e');
      }
    }

    return results.isEmpty ? _fallbackPlanets() : results;
  }

  static Map<String, dynamic>? _parseHorizonsEphemeris(
    String raw,
    String name,
  ) {
    try {
      final soe = raw.indexOf(r'$$SOE');
      final eoe = raw.indexOf(r'$$EOE');
      if (soe == -1 || eoe == -1) return null;

      final block = raw.substring(soe + 5, eoe).trim();
      final lines = block
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.length < 2) return null;

      final line1 = lines[0];
      final raMatch = RegExp(
        r'(\d{2})\s+(\d{2})\s+(\d{2}\.\d+)\s+([+-]\d{2})\s+(\d{2})\s+(\d{2}\.\d+)',
      ).firstMatch(line1);

      double ra = 0, dec = 0, mag = 5.0;
      if (raMatch != null) {
        final raH = double.parse(raMatch.group(1)!);
        final raM = double.parse(raMatch.group(2)!);
        final raS = double.parse(raMatch.group(3)!);
        ra = raH + raM / 60 + raS / 3600;

        final decD = double.parse(raMatch.group(4)!);
        final decM = double.parse(raMatch.group(5)!);
        final decS = double.parse(raMatch.group(6)!);
        dec = decD.abs() + decM / 60 + decS / 3600;
        if (decD < 0) dec = -dec;
      }

      final magMatch = RegExp(
        r'\s([-]?\d+\.\d+)\s',
      ).firstMatch(lines.length > 1 ? lines[1] : line1);
      if (magMatch != null) {
        mag = double.tryParse(magMatch.group(1)!) ?? 5.0;
      }

      final conMatch = RegExp(
        r'[A-Z][a-z]{2}\b',
      ).firstMatch(line1.substring(20));
      final constellation = _horizonsConstellationMap(conMatch?.group(0) ?? '');

      return {
        'name': name,
        'type': 'Planet',
        'constellation': constellation,
        'ra': ra,
        'dec': dec,
        'magnitude': mag,
        'distance': _approxMagnitude(name.toLowerCase()) < 0
            ? 'Inner planet'
            : 'Outer planet',
        'gravity': _planetGravity(name),
        'avgTemp': _planetTemp(name),
        'sideralOrbit': _planetOrbit(name),
        'description':
            '$name — live position from NASA JPL Horizons. '
            'RA: ${ra.toStringAsFixed(4)}h  Dec: ${dec.toStringAsFixed(3)}°',
      };
    } catch (e) {
      print('🔴 PARSE ERROR for $name: $e');
      return null;
    }
  }

  static String _horizonsConstellationMap(String abbr) {
    const m = {
      'Tau': 'Taurus',
      'Gem': 'Gemini',
      'Ori': 'Orion',
      'Ari': 'Aries',
      'Psc': 'Pisces',
      'Aqr': 'Aquarius',
      'Cap': 'Capricorn',
      'Sgr': 'Sagittarius',
      'Sco': 'Scorpius',
      'Lib': 'Libra',
      'Vir': 'Virgo',
      'Leo': 'Leo',
      'Cnc': 'Cancer',
      'Cyg': 'Cygnus',
    };
    return m[abbr] ?? 'Unknown';
  }

  static double _planetGravity(String n) {
    const m = {
      'Mercury': 3.7,
      'Venus': 8.87,
      'Mars': 3.72,
      'Jupiter': 24.79,
      'Saturn': 10.44,
      'Uranus': 8.69,
      'Neptune': 11.15,
    };
    return m[n] ?? 9.8;
  }

  static int _planetTemp(String n) {
    const m = {
      'Mercury': 440,
      'Venus': 737,
      'Mars': 210,
      'Jupiter': 165,
      'Saturn': 134,
      'Uranus': 76,
      'Neptune': 72,
    };
    return m[n] ?? 200;
  }

  static double _planetOrbit(String n) {
    const m = {
      'Mercury': 88.0,
      'Venus': 224.7,
      'Mars': 686.97,
      'Jupiter': 4332.59,
      'Saturn': 10759.22,
      'Uranus': 30688.5,
      'Neptune': 60182.0,
    };
    return m[n] ?? 365.0;
  }

  static Map<String, double> raDecToAltAz({
    required double raDeg,
    required double decDeg,
    required double lat,
    required double lon,
  }) {
    final now = DateTime.now().toUtc();
    final jd = _julianDate(now);

    final T = (jd - 2451545.0) / 36525.0;
    double gmst =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * T * T -
        T * T * T / 38710000.0;
    gmst = gmst % 360.0;
    if (gmst < 0) gmst += 360.0;

    final lst = (gmst + lon) % 360.0;

    double ha = lst - raDeg;
    if (ha < 0) ha += 360.0;
    if (ha > 180) ha -= 360.0;

    final haRad = ha * pi / 180.0;
    final decRad = decDeg * pi / 180.0;
    final latRad = lat * pi / 180.0;

    final sinAlt =
        sin(decRad) * sin(latRad) + cos(decRad) * cos(latRad) * cos(haRad);
    final alt = asin(sinAlt.clamp(-1.0, 1.0)) * 180.0 / pi;

    final cosAz =
        (sin(decRad) - sin(alt * pi / 180.0) * sin(latRad)) /
        (cos(alt * pi / 180.0) * cos(latRad));
    double az = acos(cosAz.clamp(-1.0, 1.0)) * 180.0 / pi;
    if (sin(haRad) > 0) az = 360.0 - az;

    return {'altitude': alt, 'azimuth': az};
  }

  static String visibilityLabel(double alt) {
    if (alt < 0) return 'Below Horizon';
    if (alt < 10) return 'Near Horizon';
    if (alt < 30) return 'Low';
    if (alt < 60) return 'Good';
    return 'Excellent';
  }

  static Color visibilityColor(double alt) {
    if (alt < 0) return kDangerRed;
    if (alt < 10) return kSupernovaAmber;
    if (alt < 30) return kSupernovaAmber;
    if (alt < 60) return kCosmicTeal;
    return const Color(0xFF00FF88);
  }
}

class StarDatabaseService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;

    var databasesPath = await getDatabasesPath();
    var dbPath = p.join(databasesPath, "celestial_catalog.db");

    await Directory(databasesPath).create(recursive: true);

    var file = File(dbPath);
    bool shouldCopy = false;

    if (!await file.exists()) {
      shouldCopy = true;
    } else if (await file.length() < 1000) {
      shouldCopy = true;
      await file.delete();
    }

    if (shouldCopy) {
      ByteData data = await rootBundle.load("assets/celestial_catalog.db");
      List<int> bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await file.writeAsBytes(bytes, flush: true);
    }

    _db = await openDatabase(dbPath);
    return _db!;
  }

  static Future<List<Map<String, dynamic>>> getStarsInView(
    double minRa,
    double maxRa,
    double minDec,
    double maxDec,
  ) async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> stars = await db.query(
        'Stars',
        columns: [
          'name',
          'bf',
          'bayer',
          'flam',
          'con',
          'ra',
          'dec',
          'magnitude',
          'absmag',
          'ci',
          'spect',
          'dist_ly',
          'lum',
          'rv',
          'hip',
          'hd',
          'hr',
          'var',
          'var_min',
          'var_max',
        ],
        where: 'ra BETWEEN ? AND ? AND dec BETWEEN ? AND ? AND magnitude < 7.0',
        whereArgs: [minRa, maxRa, minDec, maxDec],
        orderBy: 'magnitude ASC',
      );
      return stars;
    } catch (e) {
      print("🔴 NATIVE DB FAULT: $e");
      return [];
    }
  }
}

class ObservationRepository {
  static final _instance = ObservationRepository._internal();
  factory ObservationRepository() => _instance;
  ObservationRepository._internal();

  static Database? _db;

  static Future<Database> get _database async {
    if (_db != null) return _db!;
    final dbPath = p.join(await getDatabasesPath(), 'observation_logs.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            targetName TEXT, objectType TEXT, constellation TEXT,
            bortleClass INTEGER, exposureSeconds REAL, focalLength REAL,
            iso INTEGER, skyClarity REAL, moonPhase TEXT,
            altitude REAL, azimuth REAL, notes TEXT,
            gearLoadout TEXT, observedAt TEXT
          )
        ''');
      },
    );
    return _db!;
  }

  Future<List<ObservationLog>> fetchLogs() async {
    final db = await _database;
    final rows = await db.query('logs', orderBy: 'observedAt DESC');
    return rows.map((r) => ObservationLog.fromJson(r)).toList();
  }

  Future<void> saveLog(ObservationLog log) async {
    final db = await _database;
    await db.insert('logs', log.toJson()..remove('id'));
  }

  Future<void> deleteLog(int id) async {
    final db = await _database;
    await db.delete('logs', where: 'id = ?', whereArgs: [id]);
  }
}

const kDeepSpace = Color(0xFF000000);
const kBrilliantWhite = Color(0xFFFFFFFF);
const kNebulaIndigo = Color(0xFF141830);
const kGlassDark = Color(0xFF1C2140);
const kCosmicTeal = Color(0xFF00F2CC);
const kNebulaPurple = Color(0xFF9B5DE5);
const kSupernovaAmber = Color(0xFFFFB347);
const kStarlightWhite = Color(0xFFF8FAFC);
const kFaintStar = Color(0xFFE2E8F0);
const kDangerRed = Color(0xFFFF5370);
const kMoonGold = Color(0xFFFFD700);
const kPlanetBlue = Color(0xFF4FC3F7);
const kStarYellow = Color(0xFFFFF176);

String objectTypeIcon(String type) {
  switch (type.toLowerCase()) {
    case 'nebula':
      return '⬡';
    case 'galaxy':
      return '◎';
    case 'star cluster':
      return '✦';
    case 'supernova remnant':
      return '✸';
    case 'planet':
      return '◯';
    case 'star':
      return '★';
    default:
      return '✺';
  }
}

Color objectTypeColor(String type) {
  switch (type.toLowerCase()) {
    case 'nebula':
      return kNebulaPurple;
    case 'galaxy':
      return kCosmicTeal;
    case 'star cluster':
      return kSupernovaAmber;
    case 'supernova remnant':
      return kDangerRed;
    case 'planet':
      return kPlanetBlue;
    case 'star':
      return kStarYellow;
    default:
      return kStarlightWhite;
  }
}

String moonPhaseEmoji(String phase) {
  switch (phase.toLowerCase()) {
    case 'new moon':
      return '🌑';
    case 'waxing crescent':
      return '🌒';
    case 'first quarter':
      return '🌓';
    case 'waxing gibbous':
      return '🌔';
    case 'full moon':
      return '🌕';
    case 'waning gibbous':
      return '🌖';
    case 'last quarter':
      return '🌗';
    case 'waning crescent':
      return '🌘';
    default:
      return '🌙';
  }
}

class _ArcMeterPainter extends CustomPainter {
  final double value;
  final Color color;
  const _ArcMeterPainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 - 4;
    const startAngle = pi * 0.75;
    const sweepFull = pi * 1.5;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      startAngle,
      sweepFull,
      false,
      Paint()
        ..color = kFaintStar.withOpacity(0.15)
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      startAngle,
      sweepFull * value,
      false,
      Paint()
        ..color = color
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, value > 0.5 ? 2 : 0),
    );
  }

  @override
  bool shouldRepaint(_ArcMeterPainter old) => old.value != value;
}

class StarfieldPainter extends CustomPainter {
  final List<Offset> stars;
  final List<double> sizes;
  final List<double> opacities;
  final double shimmerPhase;

  StarfieldPainter({
    required this.stars,
    required this.sizes,
    required this.opacities,
    this.shimmerPhase = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final nebulaPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.5),
        radius: 0.7,
        colors: [const Color(0xFF9B5DE5).withOpacity(0.04), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), nebulaPaint);

    final nebulaPaint2 = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.6, 0.3),
        radius: 0.5,
        colors: [const Color(0xFF00F2CC).withOpacity(0.03), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), nebulaPaint2);

    for (int i = 0; i < stars.length; i++) {
      final shimmer = (sin(shimmerPhase + i * 0.7) + 1) / 2;
      final isDistant = i > stars.length * 0.6;
      final isMid = i > stars.length * 0.3 && !isDistant;

      final op =
          (opacities[i] *
                  (isDistant
                      ? 0.85
                      : isMid
                      ? 0.95
                      : 1.0) *
                  (0.85 + shimmer * 0.15))
              .clamp(0.0, 1.0);

      final paint = Paint()
        ..color = const Color(0xFFFFFFFF).withOpacity(op)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;

      final px = stars[i].dx * size.width;
      final py = stars[i].dy * size.height;

      final starSize = sizes[i] < 1.0 ? 1.0 : sizes[i];
      canvas.drawCircle(Offset(px, py), starSize, paint);

      if (!isDistant && sizes[i] > 1.2) {
        canvas.drawCircle(
          Offset(px, py),
          sizes[i] * 2.5,
          Paint()
            ..color = const Color(0xFFFFFFFF).withOpacity(op * 0.45)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
        );
      }
    }

    final shootingPhase = (shimmerPhase / (2 * pi)) % 1.0;
    if (shootingPhase > 0.85) {
      final t = (shootingPhase - 0.85) / 0.15;
      final sx = 0.1 + t * 0.5;
      final sy = 0.05 + t * 0.2;
      final ex = sx - 0.08 * t;
      final ey = sy + 0.04 * t;
      canvas.drawLine(
        Offset(sx * size.width, sy * size.height),
        Offset(ex * size.width, ey * size.height),
        Paint()
          ..color = const Color(0xFFE8EDF5).withOpacity((1 - t) * 0.9)
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
      );
    }
  }

  @override
  bool shouldRepaint(StarfieldPainter old) => true;
}

class StarfieldBackground extends StatefulWidget {
  final Widget child;
  const StarfieldBackground({super.key, required this.child});
  @override
  State<StarfieldBackground> createState() => _StarfieldBackgroundState();
}

class _StarfieldBackgroundState extends State<StarfieldBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late List<Offset> _stars;
  late List<Offset> _velocities;
  late List<double> _sizes, _opacities;

  @override
  void initState() {
    super.initState();
    final rng = Random(42);
    _stars = List.generate(
      160,
      (_) => Offset(rng.nextDouble(), rng.nextDouble()),
    );
    _velocities = List.generate(
      160,
      (_) => Offset(
        (rng.nextDouble() - 0.5) * 0.0007,
        (rng.nextDouble() - 0.5) * 0.0007,
      ),
    );
    _sizes = List.generate(160, (_) => rng.nextDouble() * 1.6 + 0.5);
    _opacities = List.generate(160, (_) => rng.nextDouble() * 0.5 + 0.5);

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _ctrl.addListener(_updatePhysics);
  }

  void _updatePhysics() {
    for (int i = 0; i < _stars.length; i++) {
      double nx = _stars[i].dx + _velocities[i].dx;
      double ny = _stars[i].dy + _velocities[i].dy;
      double vx = _velocities[i].dx;
      double vy = _velocities[i].dy;

      if (nx <= 0 || nx >= 1.0) vx = -vx;
      if (ny <= 0 || ny >= 1.0) vy = -vy;

      nx = nx.clamp(0.0, 1.0);
      ny = ny.clamp(0.0, 1.0);

      _stars[i] = Offset(nx, ny);
      _velocities[i] = Offset(vx, vy);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.1, -0.4),
              radius: 1.6,
              colors: [Color(0xFF000000), Color(0xFF000000), Color(0xFF000000)],
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(
            painter: StarfieldPainter(
              stars: _stars,
              sizes: _sizes,
              opacities: _opacities,
              shimmerPhase: _ctrl.value * 2 * pi,
            ),
            size: Size.infinite,
          ),
        ),
        widget.child,
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color borderColor;
  final double borderRadius;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor = kCosmicTeal,
    this.borderRadius = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: const Color(0xFF0E111D).withOpacity(0.88),
        border: Border.all(color: borderColor.withOpacity(0.28), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(height: 1, color: borderColor.withOpacity(0.5)),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

class SkyPositionPainter extends CustomPainter {
  final double altitude;
  final double azimuth;
  final Color objectColor;
  final String objectIcon;

  const SkyPositionPainter({
    required this.altitude,
    required this.azimuth,
    required this.objectColor,
    required this.objectIcon,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = const Color(0xFF020308),
    );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..color = objectColor.withOpacity(0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    for (final f in [0.25, 0.5]) {
      canvas.drawRect(
        Rect.fromLTWH(w * f, h * f, w * (1 - 2 * f), h * (1 - 2 * f)),
        Paint()
          ..color = objectColor.withOpacity(0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5,
      );
    }

    final xPaint = Paint()
      ..color = objectColor.withOpacity(0.25)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(cx, 0), Offset(cx, h), xPaint);
    canvas.drawLine(Offset(0, cy), Offset(w, cy), xPaint);

    final cStyle = TextStyle(
      color: objectColor,
      fontSize: 9,
      fontWeight: FontWeight.w700,
      letterSpacing: 1,
    );
    _txt(canvas, 'N', Offset(cx, 6), cStyle, center: true);
    _txt(canvas, 'S', Offset(cx, h - 15), cStyle, center: true);
    _txt(canvas, 'W', Offset(6, cy - 6), cStyle);
    _txt(canvas, 'E', Offset(w - 14, cy - 6), cStyle);

    if (altitude >= -5) {
      final clampedAlt = altitude.clamp(0.0, 90.0);
      final dist = 1.0 - (clampedAlt / 90.0);
      final azRad = azimuth * pi / 180.0;
      final ox = cx + (cx - 6) * dist * sin(azRad);
      final oy = cy - (cy - 6) * dist * cos(azRad);

      canvas.drawLine(
        Offset(cx, cy),
        Offset(ox, oy),
        Paint()
          ..color = objectColor.withOpacity(0.45)
          ..strokeWidth = 0.8,
      );

      canvas.drawRect(
        Rect.fromCenter(center: Offset(ox, oy), width: 16, height: 16),
        Paint()
          ..color = objectColor.withOpacity(0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );

      canvas.drawRect(
        Rect.fromCenter(center: Offset(ox, oy), width: 6, height: 6),
        Paint()..color = objectColor,
      );

      canvas.drawRect(
        Rect.fromCenter(center: Offset(ox, oy), width: 14, height: 14),
        Paint()
          ..color = objectColor.withOpacity(0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: 4, height: 4),
        Paint()..color = objectColor.withOpacity(0.4),
      );

      _txt(
        canvas,
        '${altitude.toStringAsFixed(1)}°',
        Offset(ox + 9, oy - 10),
        TextStyle(color: objectColor, fontSize: 8, fontWeight: FontWeight.w700),
      );
    } else {
      final azRad = azimuth * pi / 180.0;
      final ex = cx + (cx - 8) * sin(azRad);
      final ey = cy - (cy - 8) * cos(azRad);
      canvas.drawRect(
        Rect.fromCenter(center: Offset(ex, ey), width: 6, height: 6),
        Paint()..color = kDangerRed.withOpacity(0.7),
      );
      _txt(
        canvas,
        'BELOW',
        Offset(ex + 8, ey - 5),
        const TextStyle(color: kDangerRed, fontSize: 7),
      );
    }
  }

  void _txt(
    Canvas canvas,
    String t,
    Offset pos,
    TextStyle style, {
    bool center = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center ? pos.dx - tp.width / 2 : pos.dx, pos.dy));
  }

  @override
  bool shouldRepaint(SkyPositionPainter o) =>
      o.altitude != altitude || o.azimuth != azimuth;
}

class SkyPositionWidget extends StatelessWidget {
  final double altitude;
  final double azimuth;
  final Color objectColor;
  final String objectIcon;
  final String objectName;

  const SkyPositionWidget({
    super.key,
    required this.altitude,
    required this.azimuth,
    required this.objectColor,
    required this.objectIcon,
    required this.objectName,
  });

  @override
  Widget build(BuildContext context) {
    final visLabel = LiveSkyService.visibilityLabel(altitude);
    final visColor = LiveSkyService.visibilityColor(altitude);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E111D).withOpacity(0.88),
        border: Border.all(color: objectColor.withOpacity(0.28), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: objectColor.withOpacity(0.05),
              border: Border(
                bottom: BorderSide(color: objectColor.withOpacity(0.18)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'SKY POSITION NOW',
                  style: TextStyle(
                    color: kFaintStar,
                    fontSize: 8,
                    letterSpacing: 3,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: visColor.withOpacity(0.7)),
                    color: visColor.withOpacity(0.08),
                  ),
                  child: Text(
                    visLabel.toUpperCase(),
                    style: TextStyle(
                      color: visColor,
                      fontSize: 7,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: double.infinity,
              height: 200,
              child: CustomPaint(
                painter: SkyPositionPainter(
                  altitude: altitude,
                  azimuth: azimuth,
                  objectColor: objectColor,
                  objectIcon: objectIcon,
                ),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: objectColor.withOpacity(0.18)),
              ),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  _StatBox(
                    'ALTITUDE',
                    '${altitude.toStringAsFixed(1)}°',
                    objectColor,
                  ),
                  Container(width: 1, color: objectColor.withOpacity(0.18)),
                  _StatBox(
                    'AZIMUTH',
                    '${azimuth.toStringAsFixed(1)}°',
                    objectColor,
                  ),
                  Container(width: 1, color: objectColor.withOpacity(0.18)),
                  _StatBox('DIRECTION', _azToCardinal(azimuth), kCosmicTeal),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _StatBox(String label, String value, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      color: color.withOpacity(0.04),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: kFaintStar,
              fontSize: 7,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    ),
  );

  String _azToCardinal(double az) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW', 'N'];
    return dirs[((az + 22.5) / 45).floor() % 8];
  }
}

class _SkyStatPill extends StatelessWidget {
  final String label, value;
  final Color color;
  const _SkyStatPill({
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: TextStyle(color: kFaintStar, fontSize: 7, letterSpacing: 2),
      ),
    ],
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const NebulaTrackApp());
}

class NebulaTrackApp extends StatelessWidget {
  const NebulaTrackApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kDeepSpace,
        fontFamily: 'Courier',
        colorScheme: const ColorScheme.dark(
          primary: kCosmicTeal,
          secondary: kNebulaPurple,
          surface: kNebulaIndigo,
          error: kDangerRed,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: kStarlightWhite,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
            fontFamily: 'Courier',
          ),
          iconTheme: IconThemeData(color: kCosmicTeal),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: kCosmicTeal,
          inactiveTrackColor: kFaintStar.withOpacity(0.3),
          thumbColor: kCosmicTeal,
          overlayColor: kCosmicTeal.withOpacity(0.15),
          valueIndicatorColor: kNebulaIndigo,
          valueIndicatorTextStyle: const TextStyle(
            color: kStarlightWhite,
            fontSize: 11,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kNebulaIndigo.withOpacity(0.5),
          labelStyle: const TextStyle(
            color: kCosmicTeal,
            fontSize: 11,
            letterSpacing: 2,
          ),
          hintStyle: TextStyle(
            color: kFaintStar.withOpacity(0.6),
            fontSize: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kFaintStar),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kFaintStar),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kCosmicTeal, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDangerRed),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDangerRed, width: 1.5),
          ),
        ),
      ),
      home: const CosmicDashboardScreen(),
    );
  }
}

class CosmicScaleRoute extends PageRouteBuilder {
  final Widget page;
  CosmicScaleRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionDuration: const Duration(milliseconds: 600),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          );
        },
      );
}

class CosmicSlideRoute extends PageRouteBuilder {
  final Widget page;
  CosmicSlideRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutQuart,
                    ),
                  ),
              child: child,
            ),
          );
        },
      );
}

class CosmicDashboardScreen extends StatefulWidget {
  const CosmicDashboardScreen({super.key});
  @override
  State<CosmicDashboardScreen> createState() => _CosmicDashboardScreenState();
}

class _CosmicDashboardScreenState extends State<CosmicDashboardScreen>
    with TickerProviderStateMixin {
  final _repo = ObservationRepository();
  List<ObservationLog> _logs = [];
  List<Map<String, dynamic>> _dsoList = [];
  List<Map<String, dynamic>> _planets = [];
  List<Map<String, dynamic>> _stars = [];
  Map<String, dynamic> _sky = {};
  bool _isLoading = true;
  int _tabIndex = 0;

  late AnimationController _pulseCtrl;
  late AnimationController _tabCtrl;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _tabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _loadAll();
  }

  String _conFullName(String abbr) {
    const map = {
      'And': 'Andromeda',
      'Ant': 'Antlia',
      'Aps': 'Apus',
      'Aqr': 'Aquarius',
      'Aql': 'Aquila',
      'Ara': 'Ara',
      'Ari': 'Aries',
      'Aur': 'Auriga',
      'Boo': 'Boötes',
      'Cae': 'Caelum',
      'Cam': 'Camelopardalis',
      'Cnc': 'Cancer',
      'CVn': 'Canes Venatici',
      'CMa': 'Canis Major',
      'CMi': 'Canis Minor',
      'Cap': 'Capricornus',
      'Car': 'Carina',
      'Cas': 'Cassiopeia',
      'Cen': 'Centaurus',
      'Cep': 'Cepheus',
      'Cet': 'Cetus',
      'Col': 'Columba',
      'Com': 'Coma Berenices',
      'CrA': 'Corona Australis',
      'CrB': 'Corona Borealis',
      'Crv': 'Corvus',
      'Crt': 'Crater',
      'Cru': 'Crux',
      'Cyg': 'Cygnus',
      'Del': 'Delphinus',
      'Dor': 'Dorado',
      'Dra': 'Draco',
      'Equ': 'Equuleus',
      'Eri': 'Eridanus',
      'For': 'Fornax',
      'Gem': 'Gemini',
      'Gru': 'Grus',
      'Her': 'Hercules',
      'Hor': 'Horologium',
      'Hya': 'Hydra',
      'Hyi': 'Hydrus',
      'Ind': 'Indus',
      'Lac': 'Lacerta',
      'Leo': 'Leo',
      'LMi': 'Leo Minor',
      'Lep': 'Lepus',
      'Lib': 'Libra',
      'Lup': 'Lupus',
      'Lyn': 'Lynx',
      'Lyr': 'Lyra',
      'Men': 'Mensa',
      'Mic': 'Microscopium',
      'Mon': 'Monoceros',
      'Mus': 'Musca',
      'Nor': 'Norma',
      'Oct': 'Octans',
      'Oph': 'Ophiuchus',
      'Ori': 'Orion',
      'Pav': 'Pavo',
      'Peg': 'Pegasus',
      'Per': 'Perseus',
      'Phe': 'Phoenix',
      'Pic': 'Pictor',
      'Psc': 'Pisces',
      'PsA': 'Piscis Austrinus',
      'Pup': 'Puppis',
      'Pyx': 'Pyxis',
      'Ret': 'Reticulum',
      'Sge': 'Sagitta',
      'Sgr': 'Sagittarius',
      'Sco': 'Scorpius',
      'Scl': 'Sculptor',
      'Sct': 'Scutum',
      'Ser': 'Serpens',
      'Sex': 'Sextans',
      'Tau': 'Taurus',
      'Tel': 'Telescopium',
      'Tri': 'Triangulum',
      'TrA': 'Triangulum Australe',
      'Tuc': 'Tucana',
      'UMa': 'Ursa Major',
      'UMi': 'Ursa Minor',
      'Vel': 'Vela',
      'Vir': 'Virgo',
      'Vol': 'Volans',
      'Vul': 'Vulpecula',
    };
    return map[abbr] ?? abbr;
  }

  String _buildStarDescription(Map<String, dynamic> s) {
    final parts = <String>[];
    if (s['spect'] != null) parts.add('Spectral class ${s['spect']}');
    if (s['dist_ly'] != null)
      parts.add(
        '${(s['dist_ly'] as double).toStringAsFixed(1)} light years away',
      );
    if (s['lum'] != null)
      parts.add('${(s['lum'] as double).toStringAsFixed(2)}× solar luminosity');
    if (s['rv'] != null)
      parts.add(
        'Radial velocity ${(s['rv'] as double).toStringAsFixed(1)} km/s',
      );
    if (s['var'] != null) parts.add('Variable star type: ${s['var']}');
    return parts.isEmpty
        ? 'Star from the HYG v4.2 catalogue.'
        : parts.join('. ') + '.';
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);

    try {
      final results = await Future.wait([
        _repo.fetchLogs(),
        LiveSkyService.fetchSkyConditions(),
        LiveSkyService.fetchDSOFromAsset(),
        LiveSkyService.fetchPlanetPositions(),
        StarDatabaseService.getStarsInView(0.0, 24.0, -90.0, 90.0),
      ]);

      setState(() {
        _logs = results[0] as List<ObservationLog>;
        _sky = results[1] as Map<String, dynamic>;
        _dsoList = results[2] as List<Map<String, dynamic>>;
        _planets = results[3] as List<Map<String, dynamic>>;
        _stars = results[4] as List<Map<String, dynamic>>;

        _isLoading = false;
        print("UI UPDATED: Stars list now contains ${_stars.length} items.");
      });
    } catch (e) {
      print("CRITICAL ERROR: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDeepSpace,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      body: StarfieldBackground(
        child: _isLoading ? _buildLoader() : _buildBody(),
      ),
      floatingActionButton: _buildFAB(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF020308),
          border: Border(
            bottom: BorderSide(color: Color(0xFF1A2A25), width: 1),
          ),
        ),
      ),
      title: Row(
        children: [
          Icon(
            Icons.settings_input_antenna_rounded,
            color: kFaintStar.withOpacity(0.5),
            size: 18,
          ),
          const SizedBox(width: 10),

          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) => Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kCosmicTeal,
                boxShadow: [
                  BoxShadow(
                    color: kCosmicTeal.withOpacity(_pulseCtrl.value * 0.6),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              "ASTRA_CORE v2.1",
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 3,
                color: kStarlightWhite,
              ),
            ),
          ),

          GestureDetector(
            onTap: _loadAll,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                border: Border.all(color: kCosmicTeal.withOpacity(0.35)),
                color: kCosmicTeal.withOpacity(0.06),
              ),
              child: const Icon(
                Icons.wifi_tethering_rounded,
                color: kCosmicTeal,
                size: 14,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildLoader() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: kCosmicTeal,
              backgroundColor: kFaintStar.withOpacity(0.2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "SCANNING DEEP SPACE...",
            style: TextStyle(
              color: kCosmicTeal.withOpacity(0.7),
              fontSize: 10,
              letterSpacing: 3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 105, 20, 0),
            child: _buildSkyConditionsCard(),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: _buildMissionSummary(),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: _buildTabBar(),
          ),
        ),
        _buildSearchBar(),
        if (_tabIndex == 0) ..._buildMyLogs(),
        if (_tabIndex == 1) ..._buildDSOList(),
        if (_tabIndex == 2) ..._buildPlanetList(),
        if (_tabIndex == 3) ..._buildStarList(),
        const SliverToBoxAdapter(child: SizedBox(height: 110)),
      ],
    );
  }

  Widget _buildSkyConditionsCard() {
    final moonPhase = _sky['moonPhase'] ?? LiveSkyService._computeMoonPhase();
    final moonEmoji = moonPhaseEmoji(moonPhase);
    final skyClarity = (_sky['skyClarity'] as double? ?? 78.0);
    final humidity = _sky['humidity'] ?? 55;
    final location = (_sky['location'] ?? 'SCANNING...') as String;

    return GlassCard(
      borderColor: kMoonGold,
      padding: const EdgeInsets.all(0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 60,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [kMoonGold.withOpacity(0.04), Colors.transparent],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kMoonGold.withOpacity(0.1),
                          border: Border.all(color: kMoonGold.withOpacity(0.3)),
                        ),
                        child: const Icon(
                          Icons.wb_twilight_rounded,
                          color: kMoonGold,
                          size: 12,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          location.toUpperCase(),
                          style: const TextStyle(
                            color: kFaintStar,
                            fontSize: 9,
                            letterSpacing: 2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: kCosmicTeal.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: kCosmicTeal.withOpacity(0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AnimatedBuilder(
                              animation: _pulseCtrl,
                              builder: (_, __) => Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kCosmicTeal,
                                  boxShadow: [
                                    BoxShadow(
                                      color: kCosmicTeal.withOpacity(
                                        _pulseCtrl.value,
                                      ),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              "LIVE",
                              style: TextStyle(
                                color: kCosmicTeal,
                                fontSize: 7,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Row(
                    children: [
                      Expanded(
                        child: _SkyMetricTile(
                          emoji: moonEmoji,
                          label: "MOON",
                          value: moonPhase.split(' ').last,
                          subValue: moonPhase,
                          color: kMoonGold,
                        ),
                      ),
                      _vDiv(),

                      Expanded(
                        child: Column(
                          children: [
                            SizedBox(
                              width: 52,
                              height: 52,
                              child: CustomPaint(
                                painter: _ArcMeterPainter(
                                  value: skyClarity / 100,
                                  color: skyClarity > 80
                                      ? kCosmicTeal
                                      : skyClarity > 60
                                      ? kSupernovaAmber
                                      : kDangerRed,
                                ),
                                child: Center(
                                  child: Text(
                                    "${skyClarity.toStringAsFixed(0)}%",
                                    style: TextStyle(
                                      color: skyClarity > 80
                                          ? kCosmicTeal
                                          : kSupernovaAmber,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "CLARITY",
                              style: TextStyle(
                                color: kFaintStar,
                                fontSize: 7,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _vDiv(),

                      Expanded(
                        child: _SkyMetricTile(
                          emoji: '💧',
                          label: "HUMIDITY",
                          value: "$humidity%",
                          subValue: humidity < 50 ? "Dry" : "Moist",
                          color: kNebulaPurple,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vDiv() =>
      Container(height: 44, width: 1, color: kFaintStar.withOpacity(0.25));

  Widget _buildMissionSummary() {
    final galaxyCount = _logs
        .where((l) => l.objectType.toLowerCase() == 'galaxy')
        .length;
    final nebulaCount = _logs
        .where((l) => l.objectType.toLowerCase() == 'nebula')
        .length;
    final avgClarity = _logs.isEmpty
        ? 0.0
        : _logs.map((l) => l.skyClarity).reduce((a, b) => a + b) / _logs.length;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E111D).withOpacity(0.88),
        border: Border.all(color: kCosmicTeal.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: kCosmicTeal.withOpacity(0.04),
              border: Border(
                bottom: BorderSide(color: kCosmicTeal.withOpacity(0.15)),
              ),
            ),
            child: Text(
              "MISSION_SUMMARY",
              style: TextStyle(
                color: kFaintStar,
                fontSize: 8,
                letterSpacing: 3,
              ),
            ),
          ),

          IntrinsicHeight(
            child: Row(
              children: [
                _MissionStatCell(
                  label: "TOTAL.LOGS",
                  value: _logs.length.toString().padLeft(3, '0'),
                  color: kStarlightWhite,
                ),
                Container(width: 1, color: kCosmicTeal.withOpacity(0.15)),
                _MissionStatCell(
                  label: "GALAXIES",
                  value: galaxyCount.toString().padLeft(3, '0'),
                  color: kCosmicTeal,
                ),
              ],
            ),
          ),
          Container(height: 1, color: kCosmicTeal.withOpacity(0.15)),
          IntrinsicHeight(
            child: Row(
              children: [
                _MissionStatCell(
                  label: "NEBULAE",
                  value: nebulaCount.toString().padLeft(3, '0'),
                  color: kNebulaPurple,
                ),
                Container(width: 1, color: kCosmicTeal.withOpacity(0.15)),
                _MissionStatCell(
                  label: "AVG.CLARITY",
                  value: "${avgClarity.toStringAsFixed(1)}%",
                  color: kCosmicTeal,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    const tabs = ["LOGS", "DEEP SKY", "PLANETS", "STARS"];
    const tabIcons = [
      Icons.format_list_bulleted_rounded,
      Icons.blur_on_rounded,
      Icons.circle_outlined,
      Icons.star_rounded,
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kGlassDark.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kFaintStar.withOpacity(0.3)),
      ),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final sel = i == _tabIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _tabIndex = i;
                _searchController.clear();
                _searchQuery = '';
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: sel
                      ? kCosmicTeal.withOpacity(0.12)
                      : Colors.transparent,
                  border: sel
                      ? Border.all(color: kCosmicTeal.withOpacity(0.35))
                      : Border.all(color: Colors.transparent),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tabIcons[i],
                      size: 14,

                      color: sel
                          ? kCosmicTeal
                          : kStarlightWhite.withOpacity(0.85),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tabs[i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: sel
                            ? kCosmicTeal
                            : kStarlightWhite.withOpacity(0.85),
                        fontSize: 8,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildSearchBar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: kGlassDark.withOpacity(0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kFaintStar.withOpacity(0.3)),
          ),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: kStarlightWhite, fontSize: 13),
            onChanged: (value) =>
                setState(() => _searchQuery = value.toLowerCase()),
            decoration: InputDecoration(
              hintText: "Search items...",
              hintStyle: TextStyle(
                color: kFaintStar.withOpacity(0.5),
                fontSize: 13,
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: kFaintStar.withOpacity(0.5),
                size: 18,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear_rounded,
                        color: kFaintStar,
                        size: 16,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMyLogs() {
    final filtered = _searchQuery.isEmpty
        ? _logs
        : _logs
              .where(
                (l) =>
                    l.targetName.toLowerCase().contains(_searchQuery) ||
                    l.objectType.toLowerCase().contains(_searchQuery) ||
                    l.constellation.toLowerCase().contains(_searchQuery),
              )
              .toList();

    if (filtered.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                _searchQuery.isEmpty
                    ? "NO OBSERVATIONS LOGGED YET\nTap + to begin."
                    : "NO RESULTS FOR \"${_searchQuery.toUpperCase()}\"",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kFaintStar,
                  fontSize: 11,
                  letterSpacing: 2,
                  height: 2,
                ),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _SectionHeader(
            label: "MY OBSERVATIONS",
            count: "${filtered.length} ENTRIES",
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (ctx, i) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: _ObservationCard(
              log: filtered[i],
              index: i,
              onTap: () async {
                await Navigator.push(
                  context,
                  CosmicScaleRoute(
                    page: SpectacleDetailScreen(
                      logItem: filtered[i],
                      skyData: _sky,
                    ),
                  ),
                );
                _loadAll();
              },
            ),
          ),
          childCount: filtered.length,
        ),
      ),
    ];
  }

  List<Widget> _buildDSOList() {
    final filtered = _searchQuery.isEmpty
        ? _dsoList
        : _dsoList
              .where(
                (d) =>
                    (d['name'] as String? ?? '').toLowerCase().contains(
                      _searchQuery,
                    ) ||
                    (d['type'] as String? ?? '').toLowerCase().contains(
                      _searchQuery,
                    ) ||
                    (d['constellation'] as String? ?? '')
                        .toLowerCase()
                        .contains(_searchQuery),
              )
              .toList();

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _SectionHeader(
            label: "DEEP SKY CATALOGUE",
            count: "${filtered.length} OBJECTS",
          ),
        ),
      ),
      if (filtered.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                "NO RESULTS FOR \"${_searchQuery.toUpperCase()}\"",
                style: TextStyle(
                  color: kFaintStar,
                  fontSize: 11,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: _CatalogueCard(
                data: filtered[i],
                index: i,
                onTap: () => Navigator.push(
                  context,
                  CosmicScaleRoute(
                    page: CelestialObjectDetailScreen(
                      data: filtered[i],
                      skyData: _sky,
                    ),
                  ),
                ),
              ),
            ),
            childCount: filtered.length,
          ),
        ),
    ];
  }

  List<Widget> _buildPlanetList() {
    final filtered = _searchQuery.isEmpty
        ? _planets
        : _planets
              .where(
                (p) =>
                    (p['name'] as String? ?? '').toLowerCase().contains(
                      _searchQuery,
                    ) ||
                    (p['constellation'] as String? ?? '')
                        .toLowerCase()
                        .contains(_searchQuery),
              )
              .toList();

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _SectionHeader(
            label: "SOLAR SYSTEM",
            count: "${filtered.length} BODIES",
          ),
        ),
      ),
      if (filtered.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                "NO RESULTS FOR \"${_searchQuery.toUpperCase()}\"",
                style: TextStyle(
                  color: kFaintStar,
                  fontSize: 11,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: _PlanetCard(
                data: filtered[i],
                index: i,
                onTap: () => Navigator.push(
                  context,
                  CosmicScaleRoute(
                    page: CelestialObjectDetailScreen(
                      data: filtered[i],
                      skyData: _sky,
                    ),
                  ),
                ),
              ),
            ),
            childCount: filtered.length,
          ),
        ),
    ];
  }

  List<Widget> _buildStarList() {
    final filtered = _searchQuery.isEmpty
        ? _stars
        : _stars
              .where(
                (s) => (s['name'] as String? ?? '').toLowerCase().contains(
                  _searchQuery,
                ),
              )
              .toList();

    if (filtered.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                _searchQuery.isEmpty
                    ? "No stellar bodies located within boundary maps."
                    : "NO RESULTS FOR \"${_searchQuery.toUpperCase()}\"",
                style: TextStyle(color: kFaintStar, fontSize: 12),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _SectionHeader(
            label: "STELLAR BODIES",
            count: "${filtered.length} STARS",
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, i) {
          final starItem = filtered[i];
          final starName = starItem['name'] ?? 'Unnamed Star';
          final double? colorIndex = starItem['ci'] != null
              ? (starItem['ci'] as num).toDouble()
              : null;

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Card(
              color: Colors.transparent,
              child: ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 40,
                  child: RealisticCelestialIcon(
                    type: 'Star',
                    name: starName,
                    size: 40,
                    bvIndex: colorIndex,
                  ),
                ),
                title: Text(
                  starName,
                  style: const TextStyle(color: kBrilliantWhite),
                ),
                subtitle: Text(
                  "Magnitude: ${starItem['magnitude']}",
                  style: const TextStyle(color: kFaintStar),
                ),
                onTap: () => Navigator.push(
                  context,
                  CosmicScaleRoute(
                    page: CelestialObjectDetailScreen(
                      data: {
                        'name': starName,
                        'type': 'Star',
                        'magnitude': starItem['magnitude'],
                        'absmag': starItem['absmag'],
                        'ra': starItem['ra'],
                        'dec': starItem['dec'],
                        'ci': starItem['ci'],
                        'spect': starItem['spect'],
                        'distance': starItem['dist_ly'] != null
                            ? '${(starItem['dist_ly'] as double).toStringAsFixed(1)} ly'
                            : 'Unknown',
                        'lum': starItem['lum'],
                        'rv': starItem['rv'],
                        'constellation': starItem['con'] != null
                            ? _conFullName(starItem['con'] as String)
                            : 'Unknown',
                        'bf': starItem['bf'],
                        'var': starItem['var'],
                        'var_min': starItem['var_min'],
                        'var_max': starItem['var_max'],
                        'hip': starItem['hip'],
                        'hd': starItem['hd'],
                        'description': _buildStarDescription(starItem),
                      },
                      skyData: _sky,
                    ),
                  ),
                ),
              ),
            ),
          );
        }, childCount: filtered.length),
      ),
    ];
  }

  Widget _buildFAB() {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          CosmicSlideRoute(page: ObservationFormScreen(skyData: _sky)),
        );
        _loadAll();
      },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [kCosmicTeal, Color(0xFF00B09C)],
          ),
          boxShadow: [
            BoxShadow(
              color: kCosmicTeal.withOpacity(0.4),
              blurRadius: 22,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(Icons.add, color: kDeepSpace, size: 26),
      ),
    );
  }
}

class _SkyMetricTile extends StatelessWidget {
  final String emoji, label, value, subValue;
  final Color color;
  const _SkyMetricTile({
    required this.emoji,
    required this.label,
    required this.value,
    required this.subValue,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: kFaintStar, fontSize: 7, letterSpacing: 1.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 22,
          fontWeight: FontWeight.w300,
          letterSpacing: 2,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: TextStyle(color: kFaintStar, fontSize: 7, letterSpacing: 1.5),
      ),
    ],
  );
}

class _SectionHeader extends StatelessWidget {
  final String label, count;
  const _SectionHeader({required this.label, required this.count});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(color: kFaintStar, fontSize: 9, letterSpacing: 3),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Divider(color: kFaintStar.withOpacity(0.2), thickness: 1),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: kCosmicTeal.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kCosmicTeal.withOpacity(0.3)),
          ),
          child: Text(
            count,
            style: const TextStyle(
              color: kCosmicTeal,
              fontSize: 8,
              letterSpacing: 2,
            ),
          ),
        ),
      ],
    );
  }
}

class _ObservationCard extends StatefulWidget {
  final ObservationLog log;
  final int index;
  final VoidCallback onTap;
  const _ObservationCard({
    required this.log,
    required this.index,
    required this.onTap,
  });
  @override
  State<_ObservationCard> createState() => _ObservationCardState();
}

class _ObservationCardState extends State<_ObservationCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 350 + widget.index * 70),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.25),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final col = objectTypeColor(widget.log.objectType);
    final icon = objectTypeIcon(widget.log.objectType);
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: GestureDetector(
          onTap: widget.onTap,
          child: GlassCard(
            borderColor: col,
            padding: const EdgeInsets.all(0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [col, col.withOpacity(0.1)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 60,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerRight,
                          end: Alignment.centerLeft,
                          colors: [col.withOpacity(0.04), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: RealisticCelestialIcon(
                            type: widget.log.objectType,
                            name: widget.log.targetName,
                            size: 40,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.log.targetName.toUpperCase(),
                                style: const TextStyle(
                                  color: kStarlightWhite,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 5),
                              RichText(
                                text: TextSpan(
                                  style: const TextStyle(
                                    fontSize: 9,
                                    letterSpacing: 1,
                                    fontFamily: 'Courier',
                                  ),
                                  children: [
                                    TextSpan(
                                      text: 'TYP: ',
                                      style: TextStyle(
                                        color: kFaintStar.withOpacity(0.6),
                                      ),
                                    ),
                                    TextSpan(
                                      text: widget.log.objectType.toUpperCase(),
                                      style: TextStyle(color: col),
                                    ),
                                    TextSpan(
                                      text:
                                          '  ■  BTL: B${widget.log.bortleClass}',
                                      style: TextStyle(
                                        color: kFaintStar.withOpacity(0.5),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 3),
                              RichText(
                                text: TextSpan(
                                  style: const TextStyle(
                                    fontSize: 9,
                                    letterSpacing: 1,
                                    fontFamily: 'Courier',
                                  ),
                                  children: [
                                    TextSpan(
                                      text:
                                          '■  EXP: ${widget.log.exposureSeconds.toStringAsFixed(0)}s',
                                      style: TextStyle(
                                        color: kFaintStar.withOpacity(0.5),
                                      ),
                                    ),
                                    TextSpan(
                                      text: '  ■  ISO: ${widget.log.iso}',
                                      style: TextStyle(
                                        color: kFaintStar.withOpacity(0.5),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: kCosmicTeal.withOpacity(0.4),
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogueCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final int index;
  final VoidCallback onTap;
  const _CatalogueCard({
    required this.data,
    required this.index,
    required this.onTap,
  });
  @override
  State<_CatalogueCard> createState() => _CatalogueCardState();
}

class _CatalogueCardState extends State<_CatalogueCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 300 + widget.index * 50),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.data['type'] as String? ?? 'Unknown';
    final col = objectTypeColor(type);
    return FadeTransition(
      opacity: _fade,
      child: GestureDetector(
        onTap: widget.onTap,
        child: GlassCard(
          borderColor: col,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: RealisticCelestialIcon(
                  type: type,
                  name: widget.data['name'] as String? ?? 'Unknown',
                  size: 36,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (widget.data['name'] as String? ?? 'Unknown')
                          .toUpperCase(),
                      style: const TextStyle(
                        color: kStarlightWhite,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        _MiniTag(label: type.toUpperCase(), color: col),
                        const SizedBox(width: 6),
                        Text(
                          "${widget.data['constellation'] ?? ''}  •  mag ${(widget.data['magnitude'] ?? 0.0).toStringAsFixed(1)}",
                          style: TextStyle(
                            color: kFaintStar,
                            fontSize: 9,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                    if (widget.data['distance'] != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        "${widget.data['distance']}",
                        style: TextStyle(
                          color: kFaintStar.withOpacity(0.6),
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: kFaintStar.withOpacity(0.4),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanetCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final int index;
  final VoidCallback onTap;

  const _PlanetCard({
    required this.data,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final planetName = data['name'] as String? ?? 'Planet';

    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        borderColor: kPlanetBlue,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: RealisticCelestialIcon(
                type: 'Planet',
                name: planetName,
                size: 40,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    planetName.toUpperCase(),
                    style: const TextStyle(
                      color: kStarlightWhite,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const _MiniTag(label: "PLANET", color: kPlanetBlue),
                      const SizedBox(width: 6),
                      Text(
                        "${data['constellation'] ?? ''}  •  mag ${(data['magnitude'] ?? 0.0).toStringAsFixed(1)}",
                        style: const TextStyle(
                          color: kFaintStar,
                          fontSize: 9,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  if (data['gravity'] != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      "Gravity: ${data['gravity']} m/s²  •  Orbit: ${data['sideralOrbit']?.toStringAsFixed(0) ?? '?'} days",
                      style: TextStyle(
                        color: kFaintStar.withOpacity(0.6),
                        fontSize: 9,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: kFaintStar.withOpacity(0.4),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniTag({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 7,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class SpectacleDetailScreen extends StatefulWidget {
  final ObservationLog logItem;
  final Map<String, dynamic> skyData;
  const SpectacleDetailScreen({
    super.key,
    required this.logItem,
    required this.skyData,
  });
  @override
  State<SpectacleDetailScreen> createState() => _SpectacleDetailScreenState();
}

class _SpectacleDetailScreenState extends State<SpectacleDetailScreen>
    with TickerProviderStateMixin {
  final _repo = ObservationRepository();
  bool _isDeleting = false;
  late AnimationController _fadeCtrl;
  late AnimationController _timelineCtrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _timelineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
    Future.delayed(
      const Duration(milliseconds: 400),
      () => _timelineCtrl.forward(),
    );
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _timelineCtrl.dispose();
    super.dispose();
  }

  void _confirmDelete() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _DeleteConfirmSheet(
        targetName: widget.logItem.targetName,
        onConfirm: () async {
          Navigator.pop(context);
          setState(() => _isDeleting = true);
          await _repo.deleteLog(widget.logItem.id);
          if (mounted) Navigator.pop(context);
        },
        onCancel: () => Navigator.pop(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final col = objectTypeColor(widget.logItem.objectType);
    final icon = objectTypeIcon(widget.logItem.objectType);

    return Scaffold(
      backgroundColor: kDeepSpace,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kNebulaIndigo.withOpacity(0.7),
              border: Border.all(color: kFaintStar.withOpacity(0.3)),
            ),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: kStarlightWhite,
              size: 15,
            ),
          ),
        ),
        title: Text(
          "TARGET DETAIL",
          style: TextStyle(color: kFaintStar, fontSize: 10, letterSpacing: 4),
        ),
        centerTitle: true,
      ),
      body: StarfieldBackground(
        child: FadeTransition(
          opacity: _fade,
          child: SingleChildScrollView(
            child: Column(
              children: [
                _buildHero(col, icon),
                _buildTelemetry(col),
                _buildCameraGear(col),
                _buildBortleBar(),
                _buildCoordinates(col),
                _buildSkyDome(col),
                _buildTimelineGraph(col),
                _buildNotes(col),
                _buildDeleteSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSkyDome(Color col) {
    final lat = widget.skyData['lat'] as double? ?? 12.97;
    final lon = widget.skyData['lon'] as double? ?? 77.59;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: SkyPositionWidget(
        altitude: widget.logItem.altitude,
        azimuth: widget.logItem.azimuth,
        objectColor: col,
        objectIcon: objectTypeIcon(widget.logItem.objectType),
        objectName: widget.logItem.targetName,
      ),
    );
  }

  Widget _buildHero(Color col, String icon) {
    return Hero(
      tag: 'target-${widget.logItem.id}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 108, 24, 32),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [col.withOpacity(0.12), Colors.transparent],
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              width: 110,
              height: 110,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: col.withOpacity(0.1), width: 1),
                    ),
                  ),

                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: col.withOpacity(0.2), width: 1),
                    ),
                  ),

                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: col.withOpacity(0.08),
                      border: Border.all(
                        color: col.withOpacity(0.55),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: col.withOpacity(0.3),
                          blurRadius: 28,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        icon,
                        style: TextStyle(color: col, fontSize: 30),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              widget.logItem.targetName.toUpperCase(),
              style: const TextStyle(
                color: kStarlightWhite,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MiniTag(
                  label: widget.logItem.objectType.toUpperCase(),
                  color: col,
                ),
                const SizedBox(width: 8),
                _MiniTag(
                  label: widget.logItem.constellation.toUpperCase(),
                  color: kFaintStar,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              widget.logItem.observedAt.toString().substring(0, 16),
              style: TextStyle(
                color: kFaintStar.withOpacity(0.6),
                fontSize: 10,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetry(Color col) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: GlassCard(
        borderColor: col,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel("TELEMETRY"),
            const SizedBox(height: 14),
            _DataRow2(
              label: "CATALOG ID",
              value: "#${widget.logItem.id}",
              color: col,
            ),
            _divider(),
            _DataRow2(
              label: "OBJECT TYPE",
              value: widget.logItem.objectType,
              color: col,
            ),
            _divider(),
            _DataRow2(
              label: "CONSTELLATION",
              value: widget.logItem.constellation,
              color: kStarlightWhite,
            ),
            _divider(),
            _DataRow2(
              label: "SKY CLARITY",
              value: "${widget.logItem.skyClarity.toStringAsFixed(0)}%",
              color: kCosmicTeal,
            ),
            _divider(),
            _DataRow2(
              label: "MOON PHASE",
              value:
                  "${moonPhaseEmoji(widget.logItem.moonPhase)} ${widget.logItem.moonPhase}",
              color: kMoonGold,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraGear(Color col) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: GlassCard(
        borderColor: kNebulaPurple,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel("CAMERA GEAR LOADOUT"),
            const SizedBox(height: 14),
            _DataRow2(
              label: "GEAR",
              value: widget.logItem.gearLoadout,
              color: kNebulaPurple,
            ),
            _divider(),
            _DataRow2(
              label: "FOCAL LENGTH",
              value: "${widget.logItem.focalLength.toStringAsFixed(0)} mm",
              color: kSupernovaAmber,
            ),
            _divider(),
            _DataRow2(
              label: "ISO SENSITIVITY",
              value: "ISO ${widget.logItem.iso}",
              color: kSupernovaAmber,
            ),
            _divider(),
            _DataRow2(
              label: "EXPOSURE TIME",
              value: "${widget.logItem.exposureSeconds.toStringAsFixed(1)} s",
              color: kCosmicTeal,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBortleBar() {
    final b = widget.logItem.bortleClass;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: GlassCard(
        borderColor: kSupernovaAmber,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionLabel("BORTLE SCALE"),
                Text(
                  "CLASS $b / 9",
                  style: const TextStyle(
                    color: kSupernovaAmber,
                    fontSize: 10,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: kFaintStar.withOpacity(0.15),
              ),
              child: FractionallySizedBox(
                widthFactor: b / 9,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(
                      colors: b <= 3
                          ? [kCosmicTeal, const Color(0xFF2EC4B6)]
                          : b <= 6
                          ? [kSupernovaAmber, const Color(0xFFFF8C42)]
                          : [kDangerRed, const Color(0xFFFF3358)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (b <= 3
                                    ? kCosmicTeal
                                    : b <= 6
                                    ? kSupernovaAmber
                                    : kDangerRed)
                                .withOpacity(0.5),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "PRISTINE DARK",
                  style: TextStyle(
                    color: kFaintStar.withOpacity(0.5),
                    fontSize: 8,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  "INNER CITY",
                  style: TextStyle(
                    color: kFaintStar.withOpacity(0.5),
                    fontSize: 8,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoordinates(Color col) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: GlassCard(
        borderColor: kCosmicTeal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel("ORBITAL POSITION"),
            const SizedBox(height: 14),
            _DataRow2(
              label: "ALTITUDE",
              value: "${widget.logItem.altitude.toStringAsFixed(1)}°",
              color: kCosmicTeal,
            ),
            _divider(),
            _DataRow2(
              label: "AZIMUTH",
              value: "${widget.logItem.azimuth.toStringAsFixed(1)}°",
              color: kCosmicTeal,
            ),
            _divider(),
            const SizedBox(height: 10),
            _buildCompassWidget(),
          ],
        ),
      ),
    );
  }

  Widget _buildCompassWidget() {
    final az = widget.logItem.azimuth;
    return Center(
      child: SizedBox(
        width: 110,
        height: 110,
        child: CustomPaint(painter: _CompassPainter(azimuth: az)),
      ),
    );
  }

  Widget _buildTimelineGraph(Color col) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: GlassCard(
        borderColor: kNebulaPurple,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel("SESSION TIMELINE"),
            const SizedBox(height: 14),
            AnimatedBuilder(
              animation: _timelineCtrl,
              builder: (_, __) => _TimelineGraph(
                log: widget.logItem,
                progress: _timelineCtrl.value,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotes(Color col) {
    if (widget.logItem.notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: GlassCard(
        borderColor: kFaintStar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel("FIELD NOTES"),
            const SizedBox(height: 10),
            Text(
              widget.logItem.notes,
              style: TextStyle(
                color: kStarlightWhite.withOpacity(0.85),
                fontSize: 12,
                height: 1.7,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
      child: GestureDetector(
        onTap: _isDeleting ? null : _confirmDelete,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDangerRed.withOpacity(0.4)),
            color: kDangerRed.withOpacity(0.07),
          ),
          child: Center(
            child: _isDeleting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: kDangerRed,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.delete_outline_rounded,
                        color: kDangerRed,
                        size: 17,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "REMOVE FROM LOG",
                        style: TextStyle(
                          color: kDangerRed,
                          fontSize: 11,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String t) => Text(
    t,
    style: TextStyle(color: kFaintStar, fontSize: 8, letterSpacing: 3),
  );
  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 10),
    child: Divider(color: Color(0xFF232845), thickness: 1),
  );
}

class _CompassPainter extends CustomPainter {
  final double azimuth;
  const _CompassPainter({required this.azimuth});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 - 4;

    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = kFaintStar.withOpacity(0.1)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = kCosmicTeal.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final dirs = {'N': 0.0, 'E': pi / 2, 'S': pi, 'W': 3 * pi / 2};
    dirs.forEach((label, angle) {
      final x = cx + (r - 14) * sin(angle);
      final y = cy - (r - 14) * cos(angle);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: kFaintStar.withOpacity(0.6),
            fontSize: 8,
            letterSpacing: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
    });

    final rad = azimuth * pi / 180;
    final nx = cx + (r - 20) * sin(rad);
    final ny = cy - (r - 20) * cos(rad);
    canvas.drawLine(
      Offset(cx, cy),
      Offset(nx, ny),
      Paint()
        ..color = kCosmicTeal
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      Offset(nx, ny),
      4,
      Paint()
        ..color = kCosmicTeal
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      3,
      Paint()
        ..color = kCosmicTeal.withOpacity(0.4)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}

class _TimelineGraph extends StatelessWidget {
  final ObservationLog log;
  final double progress;
  const _TimelineGraph({required this.log, required this.progress});

  @override
  Widget build(BuildContext context) {
    final frames = max(1, (log.exposureSeconds / 5).ceil());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "FRAMES: $frames × ${(log.exposureSeconds / frames).toStringAsFixed(1)}s",
              style: const TextStyle(
                color: kFaintStar,
                fontSize: 9,
                letterSpacing: 1.5,
              ),
            ),
            Text(
              "TOTAL: ${log.exposureSeconds.toStringAsFixed(0)}s",
              style: const TextStyle(
                color: kNebulaPurple,
                fontSize: 9,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: Row(
            children: List.generate(min(frames, 16), (i) {
              final h = 0.3 + (sin(i * 0.7 + log.id * 0.1) + 1) / 2 * 0.7;
              final visible = i / min(frames, 16) <= progress;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: visible ? 40 * h : 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: visible
                          ? kNebulaPurple.withOpacity(0.4 + h * 0.4)
                          : kFaintStar.withOpacity(0.15),
                      boxShadow: visible
                          ? [
                              BoxShadow(
                                color: kNebulaPurple.withOpacity(0.3 * h),
                                blurRadius: 6,
                              ),
                            ]
                          : [],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "START",
              style: TextStyle(
                color: kFaintStar.withOpacity(0.4),
                fontSize: 7,
                letterSpacing: 1,
              ),
            ),
            Text(
              "END",
              style: TextStyle(
                color: kFaintStar.withOpacity(0.4),
                fontSize: 7,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class CelestialObjectDetailScreen extends StatefulWidget {
  final Map<String, dynamic> data;
  final Map<String, dynamic> skyData;

  const CelestialObjectDetailScreen({
    super.key,
    required this.data,
    required this.skyData,
  });

  @override
  State<CelestialObjectDetailScreen> createState() =>
      _CelestialObjectDetailScreenState();
}

class _CelestialObjectDetailScreenState
    extends State<CelestialObjectDetailScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  List<ObservationLog> _myLogs = [];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
    _checkExistingLogs();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _checkExistingLogs() async {
    final allLogs = await ObservationRepository().fetchLogs();
    final targetName = widget.data['name'] as String? ?? 'Unknown';
    if (mounted) {
      setState(() {
        _myLogs = allLogs
            .where(
              (l) => l.targetName.toLowerCase() == targetName.toLowerCase(),
            )
            .toList();
      });
    }
  }

  final headerStyle = const TextStyle(
    color: kFaintStar,
    fontSize: 10,
    letterSpacing: 3,
    fontWeight: FontWeight.w800,
  );

  final bodyStyle = const TextStyle(
    color: kStarlightWhite,
    fontSize: 13,
    height: 1.6,
    letterSpacing: 0.3,
    fontWeight: FontWeight.w400,
  );

  Widget _buildTextBlock(String title, String? text, Color color) {
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: color,
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: const TextStyle(
              color: kStarlightWhite,
              fontSize: 13,
              height: 1.6,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.data['type'] as String? ?? 'Unknown';
    final col = objectTypeColor(type);
    final icon = objectTypeIcon(type);
    final name = widget.data['name'] as String? ?? 'Unknown';
    final headerStyle = TextStyle(
      color: kStarlightWhite.withOpacity(0.7),
      fontSize: 8,
      letterSpacing: 3,
    );

    return Scaffold(
      backgroundColor: kDeepSpace,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kNebulaIndigo.withOpacity(0.7),
              border: Border.all(color: kFaintStar.withOpacity(0.3)),
            ),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: kStarlightWhite,
              size: 15,
            ),
          ),
        ),
        title: Text(
          type.toUpperCase(),
          style: TextStyle(color: kFaintStar, fontSize: 10, letterSpacing: 4),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(
              Icons.add_circle_outline_rounded,
              color: kCosmicTeal,
              size: 20,
            ),
            onPressed: () async {
              await Navigator.push(
                context,
                CosmicSlideRoute(
                  page: ObservationFormScreen(
                    skyData: widget.skyData,
                    prefillName: name,
                    prefillType: type,
                  ),
                ),
              );
              _checkExistingLogs();
            },
          ),
        ],
      ),
      body: StarfieldBackground(
        child: FadeTransition(
          opacity: _fade,
          child: SingleChildScrollView(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 108, 24, 28),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [col.withOpacity(0.12), Colors.transparent],
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: col.withOpacity(0.1),
                          boxShadow: [
                            BoxShadow(
                              color: col.withOpacity(0.25),
                              blurRadius: 32,
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                        child: Center(
                          child: RealisticCelestialIcon(
                            type: type,
                            name: name,
                            size: 88,
                            bvIndex: widget.data['ci'] != null
                                ? (widget.data['ci'] as num).toDouble()
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        name.toUpperCase(),
                        style: const TextStyle(
                          color: kStarlightWhite,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _MiniTag(label: type.toUpperCase(), color: col),
                          if (widget.data['constellation'] != null) ...[
                            const SizedBox(width: 8),
                            _MiniTag(
                              label: (widget.data['constellation'] as String)
                                  .toUpperCase(),
                              color: kFaintStar,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: GlassCard(
                    borderColor: col,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("OBJECT DATA", style: headerStyle),
                        const SizedBox(height: 12),

                        if (widget.data['subType'] != null) ...[
                          _DataRow2(
                            label: "SUB-TYPE",
                            value: widget.data['subType'],
                            color: col,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['magnitude'] != null) ...[
                          _DataRow2(
                            label: "MAGNITUDE",
                            value: "${widget.data['magnitude']}",
                            color: kStarlightWhite,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['spect'] != null) ...[
                          _DataRow2(
                            label: "SPECTRAL TYPE",
                            value: widget.data['spect'],
                            color: kStarYellow,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['absmag'] != null) ...[
                          _DataRow2(
                            label: "ABS. MAGNITUDE",
                            value: "${widget.data['absmag']}",
                            color: kStarlightWhite,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['lum'] != null) ...[
                          _DataRow2(
                            label: "LUMINOSITY",
                            value:
                                "${(widget.data['lum'] as double).toStringAsFixed(2)}× ☀",
                            color: kSupernovaAmber,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['rv'] != null) ...[
                          _DataRow2(
                            label: "RADIAL VELOCITY",
                            value:
                                "${(widget.data['rv'] as double).toStringAsFixed(1)} km/s",
                            color: kCosmicTeal,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['bf'] != null) ...[
                          _DataRow2(
                            label: "BAYER/FLAMSTEED",
                            value: widget.data['bf'],
                            color: kFaintStar,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['hip'] != null) ...[
                          _DataRow2(
                            label: "HIP NUMBER",
                            value: "HIP ${widget.data['hip']}",
                            color: kFaintStar,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['hd'] != null) ...[
                          _DataRow2(
                            label: "HD NUMBER",
                            value: "HD ${widget.data['hd']}",
                            color: kFaintStar,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['var'] != null) ...[
                          _DataRow2(
                            label: "VARIABLE TYPE",
                            value: widget.data['var'],
                            color: kDangerRed,
                          ),
                          _divider2(),
                          if (widget.data['var_min'] != null &&
                              widget.data['var_max'] != null)
                            _DataRow2(
                              label: "VAR. RANGE",
                              value:
                                  "${widget.data['var_min']} – ${widget.data['var_max']}",
                              color: kDangerRed,
                            ),
                          _divider2(),
                        ],
                        if (widget.data['surfaceBrightness'] != null) ...[
                          _DataRow2(
                            label: "SURFACE BRIGHTNESS",
                            value: "mag ${widget.data['surfaceBrightness']}",
                            color: kStarlightWhite,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['ra'] != null) ...[
                          _DataRow2(
                            label: "RIGHT ASCENSION",
                            value:
                                "${(widget.data['ra'] as num).toStringAsFixed(2)}h",
                            color: col,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['dec'] != null) ...[
                          _DataRow2(
                            label: "DECLINATION",
                            value:
                                "${(widget.data['dec'] as num).toStringAsFixed(2)}°",
                            color: col,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['distance'] != null) ...[
                          _DataRow2(
                            label: "DISTANCE",
                            value: "${widget.data['distance']}",
                            color: kCosmicTeal,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['size'] != null) ...[
                          _DataRow2(
                            label: "ANGULAR SIZE",
                            value: "${widget.data['size']}",
                            color: kSupernovaAmber,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['bestSeason'] != null) ...[
                          _DataRow2(
                            label: "BEST SEASON",
                            value: "${widget.data['bestSeason']}",
                            color: kNebulaPurple,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['difficulty'] != null) ...[
                          _DataRow2(
                            label: "DIFFICULTY",
                            value: widget.data['difficulty'].toUpperCase(),
                            color: col,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['catalogIds'] != null) ...[
                          _DataRow2(
                            label: "CATALOG IDS",
                            value: widget.data['catalogIds'],
                            color: kFaintStar,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['bestAltitude'] != null) ...[
                          _DataRow2(
                            label: "BEST ALTITUDE",
                            value: widget.data['bestAltitude'],
                            color: kCosmicTeal,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['avoidMoonPhase'] != null) ...[
                          _DataRow2(
                            label: "AVOID MOON",
                            value: widget.data['avoidMoonPhase'],
                            color: kMoonGold,
                          ),
                          _divider2(),
                        ],

                        if (widget.data['gravity'] != null) ...[
                          _DataRow2(
                            label: "GRAVITY",
                            value: "${widget.data['gravity']} m/s²",
                            color: kCosmicTeal,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['avgTemp'] != null) ...[
                          _DataRow2(
                            label: "MEAN TEMP",
                            value: "${widget.data['avgTemp']} K",
                            color: kSupernovaAmber,
                          ),
                          _divider2(),
                        ],
                        if (widget.data['sideralOrbit'] != null) ...[
                          _DataRow2(
                            label: "ORBITAL PERIOD",
                            value:
                                "${(widget.data['sideralOrbit'] as num).toStringAsFixed(1)} days",
                            color: kFaintStar,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                Builder(
                  builder: (context) {
                    final ra = (widget.data['ra'] as num?)?.toDouble();
                    final dec = (widget.data['dec'] as num?)?.toDouble();
                    final lat =
                        (widget.skyData['lat'] as num?)?.toDouble() ?? 12.97;
                    final lon =
                        (widget.skyData['lon'] as num?)?.toDouble() ?? 77.59;

                    if (ra == null || dec == null)
                      return const SizedBox.shrink();

                    final raDeg = ra > 24 ? ra : ra * 15.0;
                    final pos = LiveSkyService.raDecToAltAz(
                      raDeg: raDeg,
                      decDeg: dec,
                      lat: lat,
                      lon: lon,
                    );

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: SkyPositionWidget(
                        altitude: pos['altitude']!,
                        azimuth: pos['azimuth']!,
                        objectColor: col,
                        objectIcon: icon,
                        objectName: name,
                      ),
                    );
                  },
                ),

                if (widget.data['bestMagnification'] != null ||
                    widget.data['recommendedFilter'] != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kSupernovaAmber,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("OBSERVING GUIDE", style: headerStyle),
                          const SizedBox(height: 12),
                          if (widget.data['nakedEye'] != null) ...[
                            _DataRow2(
                              label: "NAKED EYE VISIBLE",
                              value: widget.data['nakedEye'] == true
                                  ? "YES"
                                  : "NO",
                              color: widget.data['nakedEye'] == true
                                  ? kCosmicTeal
                                  : kDangerRed,
                            ),
                            _divider2(),
                          ],
                          if (widget.data['bestMagnification'] != null) ...[
                            _DataRow2(
                              label: "BEST MAGNIFICATION",
                              value: widget.data['bestMagnification'],
                              color: kSupernovaAmber,
                            ),
                            _divider2(),
                          ],
                          if (widget.data['recommendedFilter'] != null) ...[
                            _DataRow2(
                              label: "RECOMMENDED FILTER",
                              value: widget.data['recommendedFilter'],
                              color: kNebulaPurple,
                            ),
                            _divider2(),
                          ],
                          if (widget.data['bestSeeing'] != null) ...[
                            _DataRow2(
                              label: "SEEING REQUIRED",
                              value: widget.data['bestSeeing'],
                              color: kStarlightWhite,
                            ),
                            _divider2(),
                          ],
                          if (widget.data['minAltitude'] != null) ...[
                            _DataRow2(
                              label: "MIN ALTITUDE",
                              value: "${widget.data['minAltitude']}°",
                              color: kFaintStar,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                if (widget.data['binoculars'] != null ||
                    widget.data['telescope4in'] != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kNebulaPurple,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("VISUAL APPEARANCE", style: headerStyle),
                          const SizedBox(height: 12),
                          _buildTextBlock(
                            "BINOCULARS",
                            widget.data['binoculars'],
                            kCosmicTeal,
                          ),
                          _buildTextBlock(
                            "4-INCH TELESCOPE",
                            widget.data['telescope4in'],
                            kSupernovaAmber,
                          ),
                          _buildTextBlock(
                            "8-INCH TELESCOPE",
                            widget.data['telescope8in'],
                            kSupernovaAmber,
                          ),
                          _buildTextBlock(
                            "12-INCH TELESCOPE",
                            widget.data['telescope12in'],
                            kNebulaPurple,
                          ),
                        ],
                      ),
                    ),
                  ),

                if (widget.data['imagingExposure'] != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kCosmicTeal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("ASTROPHOTOGRAPHY", style: headerStyle),
                          const SizedBox(height: 12),
                          _buildTextBlock(
                            "SUGGESTED EXPOSURE",
                            widget.data['imagingExposure'],
                            kCosmicTeal,
                          ),
                          _buildTextBlock(
                            "IMAGING NOTES",
                            widget.data['imagingNotes'],
                            kFaintStar,
                          ),
                        ],
                      ),
                    ),
                  ),

                if (widget.data['description'] != null &&
                    widget.data['description'].toString().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kFaintStar,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("DESCRIPTION", style: headerStyle),
                          const SizedBox(height: 10),
                          Text(
                            widget.data['description'] as String,
                            style: bodyStyle,
                          ),
                        ],
                      ),
                    ),
                  ),

                if (widget.data['findingMethod'] != null &&
                    widget.data['findingMethod'].toString().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kSupernovaAmber,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("HOW TO FIND IT", style: headerStyle),
                          const SizedBox(height: 10),
                          Text(
                            widget.data['findingMethod'] as String,
                            style: bodyStyle,
                          ),
                        ],
                      ),
                    ),
                  ),

                if (widget.data['nearbyObjects'] != null &&
                    (widget.data['nearbyObjects'] as List).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kFaintStar,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("NEARBY TARGETS", style: headerStyle),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: (widget.data['nearbyObjects'] as List)
                                .map(
                                  (obj) => _MiniTag(
                                    label: obj.toString().toUpperCase(),
                                    color: kFaintStar,
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (_myLogs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: GlassCard(
                      borderColor: kCosmicTeal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("PREVIOUS OBSERVATIONS", style: headerStyle),
                          const SizedBox(height: 12),
                          ..._myLogs
                              .map(
                                (log) => Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: GestureDetector(
                                    onTap: () async {
                                      await Navigator.push(
                                        context,
                                        CosmicScaleRoute(
                                          page: SpectacleDetailScreen(
                                            logItem: log,
                                            skyData: widget.skyData,
                                          ),
                                        ),
                                      );
                                      _checkExistingLogs();
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: kCosmicTeal.withOpacity(0.08),
                                        border: Border.all(
                                          color: kCosmicTeal.withOpacity(0.3),
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: RealisticCelestialIcon(
                                              type: log.objectType,
                                              name: log.targetName,
                                              size: 24,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  log.observedAt
                                                      .toString()
                                                      .substring(0, 16),
                                                  style: const TextStyle(
                                                    color: kStarlightWhite,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: 1,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  log.gearLoadout,
                                                  style: const TextStyle(
                                                    color: kFaintStar,
                                                    fontSize: 9,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Icon(
                                            Icons.chevron_right_rounded,
                                            color: kCosmicTeal.withOpacity(0.5),
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ],
                      ),
                    ),
                  ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 48),
                  child: GestureDetector(
                    onTap: () async {
                      await Navigator.push(
                        context,
                        CosmicSlideRoute(
                          page: ObservationFormScreen(
                            skyData: widget.skyData,
                            prefillName: name,
                            prefillType: type,
                          ),
                        ),
                      );
                      _checkExistingLogs();
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(
                          colors: [kCosmicTeal, Color(0xFF00B09C)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: kCosmicTeal.withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.add_circle_outline_rounded,
                            color: kDeepSpace,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "LOG THIS OBSERVATION",
                            style: TextStyle(
                              color: kDeepSpace,
                              fontSize: 11,
                              letterSpacing: 3,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider2() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 9),
    child: Divider(color: Color(0xFF232845), thickness: 1),
  );
}

class _DataRow2 extends StatelessWidget {
  final String label, value;
  final Color color;

  const _DataRow2({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2.0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kFaintStar,
            fontSize: 10,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: color == kStarlightWhite ? kBrilliantWhite : color,
              fontSize: 12,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

class _DeleteConfirmSheet extends StatelessWidget {
  final String targetName;
  final VoidCallback onConfirm, onCancel;
  const _DeleteConfirmSheet({
    required this.targetName,
    required this.onConfirm,
    required this.onCancel,
  });
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(16),
    padding: const EdgeInsets.all(26),
    decoration: BoxDecoration(
      color: kNebulaIndigo,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: kDangerRed.withOpacity(0.3)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kDangerRed.withOpacity(0.1),
            border: Border.all(color: kDangerRed.withOpacity(0.4)),
          ),
          child: const Icon(
            Icons.warning_amber_rounded,
            color: kDangerRed,
            size: 22,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          "CONFIRM DELETION",
          style: TextStyle(
            color: kStarlightWhite,
            fontSize: 13,
            letterSpacing: 3,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          "Remove ${targetName.toUpperCase()} from log? This cannot be undone.",
          textAlign: TextAlign.center,
          style: TextStyle(color: kFaintStar, fontSize: 11, height: 1.7),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: onCancel,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kFaintStar.withOpacity(0.3)),
                  ),
                  child: const Center(
                    child: Text(
                      "CANCEL",
                      style: TextStyle(
                        color: kFaintStar,
                        fontSize: 11,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: onConfirm,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: kDangerRed.withOpacity(0.12),
                    border: Border.all(color: kDangerRed.withOpacity(0.5)),
                  ),
                  child: const Center(
                    child: Text(
                      "DELETE",
                      style: TextStyle(
                        color: kDangerRed,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class ObservationFormScreen extends StatefulWidget {
  final Map<String, dynamic> skyData;
  final String? prefillName;
  final String? prefillType;
  const ObservationFormScreen({
    super.key,
    required this.skyData,
    this.prefillName,
    this.prefillType,
  });
  @override
  State<ObservationFormScreen> createState() => _ObservationFormScreenState();
}

class _ObservationFormScreenState extends State<ObservationFormScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _repo = ObservationRepository();
  bool _isSaving = false;

  final _nameCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _gearCtrl = TextEditingController();
  final _constellationCtrl = TextEditingController();

  String _selectedType = 'Nebula';
  int _bortleClass = 4;
  double _focalLength = 300.0;
  int _iso = 1600;
  double _exposureSeconds = 30.0;
  double _altitude = 45.0;
  double _azimuth = 180.0;

  late AnimationController _masterCtrl;
  late List<Animation<Offset>> _slideAnims;
  late Animation<double> _fadeAnim;

  final _typeOptions = [
    'Nebula',
    'Galaxy',
    'Star Cluster',
    'Supernova Remnant',
    'Planet',
    'Star',
    'Double Star',
    'Comet',
  ];
  final _gearPresets = [
    'ED80 + ASI294MC',
    'APO Refractor 102mm',
    'DSLR Canon 6D',
    'SCT 8" + Barlow 2×',
    'RC6" + LRGB Filters',
    'Nikon D7500 + 50mm',
  ];
  final _isoValues = [100, 200, 400, 800, 1600, 3200, 6400, 12800];

  @override
  void initState() {
    super.initState();
    if (widget.prefillName != null) _nameCtrl.text = widget.prefillName!;
    if (widget.prefillType != null) _selectedType = widget.prefillType!;

    _masterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(parent: _masterCtrl, curve: Curves.easeOut);
    _slideAnims = List.generate(
      8,
      (i) =>
          Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero).animate(
            CurvedAnimation(
              parent: _masterCtrl,
              curve: Interval(
                i * 0.07,
                0.7 + i * 0.04,
                curve: Curves.easeOutCubic,
              ),
            ),
          ),
    );

    final clarity = (widget.skyData['skyClarity'] as double? ?? 78.0);
    _masterCtrl.forward();
  }

  @override
  void dispose() {
    _masterCtrl.dispose();
    _nameCtrl.dispose();
    _notesCtrl.dispose();
    _gearCtrl.dispose();
    _constellationCtrl.dispose();
    super.dispose();
  }

  void _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      final moonPhase =
          widget.skyData['moonPhase'] as String? ??
          LiveSkyService._computeMoonPhase();
      final skyClarity = widget.skyData['skyClarity'] as double? ?? 75.0;
      final log = ObservationLog(
        id: DateTime.now().millisecondsSinceEpoch,
        targetName: _nameCtrl.text.trim(),
        objectType: _selectedType,
        constellation: _constellationCtrl.text.trim().isEmpty
            ? 'Unknown'
            : _constellationCtrl.text.trim(),
        bortleClass: _bortleClass,
        exposureSeconds: _exposureSeconds,
        focalLength: _focalLength,
        iso: _iso,
        skyClarity: skyClarity,
        moonPhase: moonPhase,
        altitude: _altitude,
        azimuth: _azimuth,
        notes: _notesCtrl.text.trim(),
        gearLoadout: _gearCtrl.text.trim().isEmpty
            ? 'Standard Kit'
            : _gearCtrl.text.trim(),
        observedAt: DateTime.now(),
      );
      await _repo.saveLog(log);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: kCosmicTeal.withOpacity(0.9),
            content: Text(
              "${log.targetName} logged successfully!",
              style: const TextStyle(color: kDeepSpace, letterSpacing: 1),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDeepSpace,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kNebulaIndigo.withOpacity(0.7),
              border: Border.all(color: kFaintStar.withOpacity(0.3)),
            ),
            child: const Icon(
              Icons.close_rounded,
              color: kStarlightWhite,
              size: 17,
            ),
          ),
        ),
        title: const Text(
          "NEW OBSERVATION",
          style: TextStyle(fontSize: 11, letterSpacing: 4),
        ),
        centerTitle: true,
      ),
      body: StarfieldBackground(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 108, 20, 40),
              children: [
                _slide(0, _buildSkyBanner()),
                const SizedBox(height: 20),

                _slide(1, _SectionLabel(label: "TARGET IDENTIFICATION")),
                const SizedBox(height: 10),
                _slide(
                  1,
                  _CosmicTextField(
                    controller: _nameCtrl,
                    label: "TARGET NAME",
                    hint: "e.g. Orion Nebula",
                    icon: Icons.my_location_rounded,
                    validator: (v) => v!.trim().isEmpty ? "Required" : null,
                  ),
                ),
                const SizedBox(height: 12),
                _slide(
                  1,
                  _CosmicTextField(
                    controller: _constellationCtrl,
                    label: "CONSTELLATION",
                    hint: "e.g. Orion",
                    icon: Icons.star_border_rounded,
                  ),
                ),
                const SizedBox(height: 12),
                _slide(
                  1,
                  _TypeChipGrid(
                    options: _typeOptions,
                    selected: _selectedType,
                    onSelect: (v) => setState(() => _selectedType = v),
                  ),
                ),
                const SizedBox(height: 20),

                _slide(2, _SectionLabel(label: "CAMERA GEAR LOADOUT")),
                const SizedBox(height: 10),
                _slide(
                  2,
                  _CosmicTextField(
                    controller: _gearCtrl,
                    label: "GEAR SETUP",
                    hint: "Telescope + Camera",
                    icon: Icons.camera_alt_outlined,
                  ),
                ),
                const SizedBox(height: 8),
                _slide(
                  2,
                  _GearPresetRow(
                    presets: _gearPresets,
                    onSelect: (v) => setState(() => _gearCtrl.text = v),
                    selected: _gearCtrl.text,
                  ),
                ),
                const SizedBox(height: 20),

                _slide(3, _SectionLabel(label: "CAPTURE PARAMETERS")),
                const SizedBox(height: 14),
                _slide(
                  3,
                  _SliderTile(
                    label: "FOCAL LENGTH",
                    unit: "mm",
                    value: _focalLength,
                    min: 14,
                    max: 2400,
                    divisions: 200,
                    color: kSupernovaAmber,
                    icon: Icons.lens_outlined,
                    onChanged: (v) => setState(() => _focalLength = v),
                  ),
                ),
                const SizedBox(height: 12),
                _slide(
                  3,
                  _ISOSelector(
                    values: _isoValues,
                    selected: _iso,
                    onSelect: (v) => setState(() => _iso = v),
                  ),
                ),
                const SizedBox(height: 12),
                _slide(
                  3,
                  _SliderTile(
                    label: "EXPOSURE DURATION",
                    unit: "s",
                    value: _exposureSeconds,
                    min: 0.5,
                    max: 300,
                    divisions: 150,
                    color: kCosmicTeal,
                    icon: Icons.shutter_speed_rounded,
                    onChanged: (v) => setState(() => _exposureSeconds = v),
                  ),
                ),
                const SizedBox(height: 20),

                _slide(4, _SectionLabel(label: "SKY CONDITIONS")),
                const SizedBox(height: 14),
                _slide(
                  4,
                  _BortleSelector(
                    selected: _bortleClass,
                    onSelect: (v) => setState(() => _bortleClass = v),
                  ),
                ),
                const SizedBox(height: 20),

                _slide(5, _SectionLabel(label: "COORDINATES")),
                const SizedBox(height: 14),
                _slide(
                  5,
                  _SliderTile(
                    label: "ALTITUDE",
                    unit: "°",
                    value: _altitude,
                    min: 0,
                    max: 90,
                    divisions: 90,
                    color: kNebulaPurple,
                    icon: Icons.height_rounded,
                    onChanged: (v) => setState(() => _altitude = v),
                  ),
                ),
                const SizedBox(height: 12),
                _slide(
                  5,
                  _SliderTile(
                    label: "AZIMUTH",
                    unit: "°",
                    value: _azimuth,
                    min: 0,
                    max: 360,
                    divisions: 360,
                    color: kNebulaPurple,
                    icon: Icons.explore_outlined,
                    onChanged: (v) => setState(() => _azimuth = v),
                  ),
                ),
                const SizedBox(height: 8),
                _slide(
                  5,
                  Center(
                    child: SizedBox(
                      height: 100,
                      width: 100,
                      child: CustomPaint(
                        painter: _CompassPainter(azimuth: _azimuth),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                _slide(6, _SectionLabel(label: "FIELD NOTES")),
                const SizedBox(height: 10),
                _slide(
                  6,
                  TextFormField(
                    controller: _notesCtrl,
                    maxLines: 4,
                    style: const TextStyle(
                      color: kStarlightWhite,
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          "Describe seeing conditions, equipment setup, visual impressions...",
                      hintStyle: TextStyle(
                        color: kFaintStar.withOpacity(0.5),
                        fontSize: 12,
                        height: 1.6,
                      ),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(bottom: 50),
                        child: Icon(
                          Icons.edit_note_rounded,
                          color: kCosmicTeal,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                _slide(7, _SubmitButton(isSaving: _isSaving, onTap: _submit)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slide(int i, Widget child) {
    return SlideTransition(
      position: _slideAnims[min(i, _slideAnims.length - 1)],
      child: child,
    );
  }

  Widget _buildSkyBanner() {
    final phase =
        widget.skyData['moonPhase'] as String? ??
        LiveSkyService._computeMoonPhase();
    final clarity = (widget.skyData['skyClarity'] as double? ?? 78.0);
    final humidity = widget.skyData['humidity'] ?? 55;
    return GlassCard(
      borderColor: kMoonGold,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Text(moonPhaseEmoji(phase), style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "TONIGHT'S CONDITIONS AUTO-FILLED",
                  style: TextStyle(
                    color: kMoonGold,
                    fontSize: 8,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "$phase  •  ${clarity.toStringAsFixed(0)}% clarity  •  ${humidity}% humidity",
                  style: TextStyle(
                    color: kStarlightWhite.withOpacity(0.8),
                    fontSize: 10,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: kCosmicTeal.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kCosmicTeal.withOpacity(0.4)),
            ),
            child: const Text(
              "LIVE",
              style: TextStyle(
                color: kCosmicTeal,
                fontSize: 7,
                letterSpacing: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        label,
        style: TextStyle(color: kFaintStar, fontSize: 8, letterSpacing: 3),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Divider(color: kFaintStar.withOpacity(0.2), thickness: 1),
      ),
    ],
  );
}

class _CosmicTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label, hint;
  final IconData icon;
  final String? Function(String?)? validator;
  const _CosmicTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.validator,
  });
  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    validator: validator,
    style: const TextStyle(
      color: kStarlightWhite,
      fontSize: 13,
      letterSpacing: 1,
    ),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, color: kCosmicTeal, size: 17),
    ),
  );
}

class _TypeChipGrid extends StatelessWidget {
  final List<String> options;
  final String selected;
  final void Function(String) onSelect;
  const _TypeChipGrid({
    required this.options,
    required this.selected,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: options.map((o) {
      final sel = selected == o;
      final col = objectTypeColor(o);
      return GestureDetector(
        onTap: () => onSelect(o),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: sel ? col.withOpacity(0.15) : kGlassDark.withOpacity(0.5),
            border: Border.all(
              color: sel ? col.withOpacity(0.7) : kFaintStar.withOpacity(0.2),
            ),
          ),
          child: Text(
            o,
            style: TextStyle(
              color: sel ? col : kFaintStar,
              fontSize: 10,
              letterSpacing: 1,
              fontWeight: sel ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        ),
      );
    }).toList(),
  );
}

class _GearPresetRow extends StatelessWidget {
  final List<String> presets;
  final String selected;
  final void Function(String) onSelect;
  const _GearPresetRow({
    required this.presets,
    required this.selected,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 30,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: presets.length,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (_, i) {
        final sel = selected == presets[i];
        return GestureDetector(
          onTap: () => onSelect(presets[i]),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: sel
                  ? kNebulaPurple.withOpacity(0.15)
                  : kGlassDark.withOpacity(0.4),
              border: Border.all(
                color: sel
                    ? kNebulaPurple.withOpacity(0.6)
                    : kFaintStar.withOpacity(0.2),
              ),
            ),
            child: Text(
              presets[i],
              style: TextStyle(
                color: sel ? kNebulaPurple : kFaintStar,
                fontSize: 9,
                letterSpacing: 0.8,
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _SliderTile extends StatelessWidget {
  final String label, unit;
  final double value, min, max;
  final int divisions;
  final Color color;
  final IconData icon;
  final void Function(double) onChanged;
  const _SliderTile({
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.color,
    required this.icon,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => GlassCard(
    borderColor: color,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 15),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: kFaintStar,
                fontSize: 9,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            Text(
              "${value.toStringAsFixed(unit == 'mm' || unit == 's' || unit == '°' ? 1 : 0)} $unit",
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: "${value.toStringAsFixed(1)} $unit",
          activeColor: color,
          inactiveColor: kFaintStar.withOpacity(0.25),
          onChanged: onChanged,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "${min.toStringAsFixed(0)}$unit",
              style: TextStyle(color: kFaintStar.withOpacity(0.4), fontSize: 8),
            ),
            Text(
              "${max.toStringAsFixed(0)}$unit",
              style: TextStyle(color: kFaintStar.withOpacity(0.4), fontSize: 8),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ISOSelector extends StatelessWidget {
  final List<int> values;
  final int selected;
  final void Function(int) onSelect;
  const _ISOSelector({
    required this.values,
    required this.selected,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) => GlassCard(
    borderColor: kSupernovaAmber,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.iso_rounded, color: kSupernovaAmber, size: 15),
            const SizedBox(width: 8),
            Text(
              "ISO SENSITIVITY",
              style: TextStyle(
                color: kFaintStar,
                fontSize: 9,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            Text(
              "ISO $selected",
              style: const TextStyle(
                color: kSupernovaAmber,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: values.map((v) {
            final sel = selected == v;
            return Expanded(
              child: GestureDetector(
                onTap: () => onSelect(v),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: sel
                        ? kSupernovaAmber.withOpacity(0.2)
                        : kGlassDark.withOpacity(0.4),
                    border: Border.all(
                      color: sel
                          ? kSupernovaAmber.withOpacity(0.7)
                          : kFaintStar.withOpacity(0.2),
                    ),
                  ),
                  child: Text(
                    v >= 1000 ? "${v ~/ 1000}k" : "$v",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: sel ? kSupernovaAmber : kFaintStar,
                      fontSize: 9,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    ),
  );
}

Color calculateStarColor(double bv) {
  double r = 0;
  double g = 0;
  double b = 0;

  if (bv < -0.4) bv = -0.4;
  if (bv > 2.0) bv = 2.0;

  if (bv < 0.0) {
    final t = (bv + 0.4) / 0.4;
    r = 155 + (100 * t);
    g = 176 + (79 * t);
    b = 255;
  } else if (bv < 0.4) {
    final t = bv / 0.4;
    r = 255;
    g = 255;
    b = 255 - (50 * t);
  } else if (bv < 1.4) {
    final t = (bv - 0.4) / 1.0;
    r = 255;
    g = 255 - (100 * t);
    b = 205 - (150 * t);
  } else {
    final t = (bv - 1.4) / 0.6;
    r = 255;
    g = 155 - (55 * t);
    b = 55 - (55 * t);
  }

  return Color.fromARGB(255, r.toInt(), g.toInt(), b.toInt());
}

class RealisticCelestialIcon extends StatelessWidget {
  final String type;
  final String name;
  final double size;
  final double? bvIndex;

  const RealisticCelestialIcon({
    super.key,
    required this.type,
    required this.name,
    this.size = 40.0,
    this.bvIndex,
  });

  @override
  Widget build(BuildContext context) {
    final t = type.toLowerCase();
    final pName = name.toLowerCase();

    if (t.contains('planet')) {
      String? imageUrl;

      if (pName.contains('mercury')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/4/4a/Mercury_in_true_color.jpg';
      } else if (pName.contains('venus')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/e/e5/Venus-real_color.jpg';
      } else if (pName.contains('earth')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/9/97/The_Earth_seen_from_Apollo_17.jpg';
      } else if (pName.contains('mars')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/0/02/OSIRIS_Mars_true_color.jpg';
      } else if (pName.contains('jupiter')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/e/e2/Jupiter.jpg';
      } else if (pName.contains('saturn')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/c/c7/Saturn_during_Equinox.jpg';
      } else if (pName.contains('uranus')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/3/3d/Uranus2.jpg';
      } else if (pName.contains('neptune')) {
        imageUrl =
            'https://upload.wikimedia.org/wikipedia/commons/6/63/Neptune_-_Voyager_2_%2829347980845%29_flatten_crop.jpg';
      }

      if (imageUrl != null) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFFFFF).withOpacity(0.15),
                blurRadius: size * 0.3,
                spreadRadius: size * 0.05,
              ),
            ],
          ),
          child: ClipOval(
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  _buildProceduralFallback(),
            ),
          ),
        );
      }
    }

    return _buildProceduralFallback();
  }

  Widget _buildProceduralFallback() {
    return CustomPaint(
      size: Size(size, size),
      painter: _CelestialPainter(type: type, seedName: name, bvIndex: bvIndex),
    );
  }
}

class _CelestialPainter extends CustomPainter {
  final String type;
  final String seedName;
  final double? bvIndex;

  _CelestialPainter({required this.type, required this.seedName, this.bvIndex});

  @override
  void paint(Canvas canvas, Size size) {
    final rand = Random(seedName.hashCode);
    final center = Offset(size.width / 2, size.height / 2);
    final t = type.toLowerCase();

    if (t.contains('star') && !t.contains('cluster')) {
      final starColor = bvIndex != null
          ? calculateStarColor(bvIndex!)
          : const Color(0xFFE8F4FF);

      final glowGradient = RadialGradient(
        colors: [
          const Color(0xFFFFFFFF),
          Color.lerp(const Color(0xFFFFFFFF), starColor, 0.4)!,
          starColor.withOpacity(0.85),
          starColor.withOpacity(0.3),
          starColor.withOpacity(0.0),
        ],
        stops: const [0.0, 0.15, 0.4, 0.75, 1.0],
      );

      final radius = size.width * 0.48;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = glowGradient.createShader(
            Rect.fromCircle(center: center, radius: radius),
          ),
      );
    } else if (t.contains('planet')) {
      final pName = seedName.toLowerCase();
      List<Color> palette;
      bool hasRings = false;
      bool isGasGiant = false;

      if (pName.contains('mars')) {
        palette = [const Color(0xFFE55938), const Color(0xFF8B3A28)];
      } else if (pName.contains('jupiter')) {
        palette = [
          const Color(0xFFD39C7E),
          const Color(0xFFC88B3A),
          const Color(0xFFE0C9A6),
        ];
        isGasGiant = true;
      } else if (pName.contains('saturn')) {
        palette = [const Color(0xFFEAD6B8), const Color(0xFFCEB8B8)];
        isGasGiant = true;
        hasRings = true;
      } else if (pName.contains('venus')) {
        palette = [const Color(0xFFE0C9A6), const Color(0xFFD3B892)];
      } else if (pName.contains('neptune')) {
        palette = [const Color(0xFF274687), const Color(0xFF3F54BA)];
      } else if (pName.contains('uranus')) {
        palette = [const Color(0xFF4CB5C5), const Color(0xFF75D5E3)];
      } else if (pName.contains('earth')) {
        palette = [const Color(0xFF4B8BBE), const Color(0xFF2E658B)];
      } else {
        palette = [const Color(0xFF9E9E9E), const Color(0xFF616161)];
      }

      final radius = size.width * 0.35;

      if (hasRings) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-pi / 8);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: radius * 4.5,
            height: radius * 1.2,
          ),
          Paint()
            ..color = palette[0].withOpacity(0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = radius * 0.4,
        );
        canvas.restore();
      }

      canvas.drawCircle(
        center,
        radius * 1.3,
        Paint()
          ..color = palette[0].withOpacity(0.2)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.5),
      );

      final gradient = RadialGradient(
        center: const Alignment(-0.3, -0.3),
        radius: 1.0,
        colors: [
          Color.lerp(palette[0], const Color(0xFFFFFFFF), 0.4)!,
          palette[0],
          palette.last,
          const Color(0xFF000000).withOpacity(0.8),
        ],
        stops: const [0.0, 0.4, 0.8, 1.0],
      );

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = gradient.createShader(
            Rect.fromCircle(center: center, radius: radius),
          ),
      );

      if (isGasGiant) {
        canvas.save();
        canvas.clipPath(
          Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
        );
        for (int i = 0; i < 4; i++) {
          final bandY = center.dy - radius + (radius * 2 * rand.nextDouble());
          final bandHeight = radius * (0.1 + rand.nextDouble() * 0.2);
          final bandColor = palette[rand.nextInt(palette.length)];
          canvas.drawRect(
            Rect.fromLTWH(center.dx - radius, bandY, radius * 2, bandHeight),
            Paint()
              ..color = bandColor.withOpacity(0.4)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.1),
          );
        }
        canvas.restore();
      }

      if (hasRings) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-pi / 8);
        canvas.clipRect(Rect.fromLTRB(-radius * 3, 0, radius * 3, radius * 3));
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: radius * 4.5,
            height: radius * 1.2,
          ),
          Paint()
            ..color = palette[0].withOpacity(0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = radius * 0.4,
        );
        canvas.restore();
      }
    } else if (t.contains('nebula') || t.contains('remnant')) {
      final baseColors = [
        const Color(0xFFE91E63),
        const Color(0xFF9C27B0),
        const Color(0xFF00BCD4),
        const Color(0xFF3F51B5),
        const Color(0xFF4CAF50),
      ];
      final c1 = baseColors[rand.nextInt(baseColors.length)];
      final c2 = baseColors[rand.nextInt(baseColors.length)];

      for (int i = 0; i < 4; i++) {
        final offsetX = (rand.nextDouble() - 0.5) * size.width * 0.5;
        final offsetY = (rand.nextDouble() - 0.5) * size.height * 0.5;
        final radius = (rand.nextDouble() * 0.3 + 0.2) * size.width;

        canvas.drawCircle(
          Offset(center.dx + offsetX, center.dy + offsetY),
          radius,
          Paint()
            ..color = (i % 2 == 0 ? c1 : c2).withOpacity(0.5)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.8),
        );
      }
    } else if (t.contains('galaxy')) {
      final angle = rand.nextDouble() * pi;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);

      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: size.width * 0.8,
        height: size.height * 0.3,
      );

      canvas.drawOval(
        rect,
        Paint()
          ..color = const Color(0xFF81D4FA).withOpacity(0.3)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.2),
      );

      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: size.width * 0.3,
          height: size.height * 0.2,
        ),
        Paint()
          ..color = const Color(0xFFFFF9C4).withOpacity(0.8)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.05),
      );

      canvas.restore();
    } else {
      canvas.drawCircle(
        center,
        size.width * 0.2,
        Paint()
          ..color = const Color(0xFFB0BEC5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BortleSelector extends StatelessWidget {
  final int selected;
  final void Function(int) onSelect;
  const _BortleSelector({required this.selected, required this.onSelect});
  static const labels = [
    '1\nPristine',
    '2\nSky',
    '3\nRural',
    '4\nSubrural',
    '5\nTransit',
    '6\nSuburb',
    '7\nSuburb+',
    '8\nCity',
    '9\nInner',
  ];
  static final colors = [
    kCosmicTeal,
    kCosmicTeal,
    const Color(0xFF2ECC71),
    const Color(0xFF27AE60),
    kSupernovaAmber,
    kSupernovaAmber,
    const Color(0xFFE67E22),
    kDangerRed,
    kDangerRed,
  ];
  @override
  Widget build(BuildContext context) => GlassCard(
    borderColor: kSupernovaAmber,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.brightness_4_outlined,
              color: kSupernovaAmber,
              size: 15,
            ),
            const SizedBox(width: 8),
            Text(
              "BORTLE CLASS",
              style: TextStyle(
                color: kFaintStar,
                fontSize: 9,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            Text(
              "CLASS $selected / 9",
              style: const TextStyle(
                color: kSupernovaAmber,
                fontSize: 12,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: List.generate(9, (i) {
            final n = i + 1;
            final sel = selected == n;
            final col = colors[i];
            return Expanded(
              child: GestureDetector(
                onTap: () => onSelect(n),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  height: sel ? 48 : 28,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    color: sel ? col.withOpacity(0.3) : col.withOpacity(0.08),
                    border: Border.all(
                      color: sel ? col : col.withOpacity(0.3),
                      width: sel ? 1.5 : 1,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      "$n",
                      style: TextStyle(
                        color: sel ? col : col.withOpacity(0.5),
                        fontSize: 10,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    ),
  );
}

class _SubmitButton extends StatefulWidget {
  final bool isSaving;
  final VoidCallback onTap;
  const _SubmitButton({required this.isSaving, required this.onTap});
  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _shimmer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _shimmer = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isSaving ? null : widget.onTap,
      child: AnimatedBuilder(
        animation: _shimmer,
        builder: (_, __) => Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: widget.isSaving
                ? LinearGradient(colors: [kFaintStar, kFaintStar])
                : LinearGradient(
                    begin: Alignment(-1 + _shimmer.value * 2, 0),
                    end: Alignment(1 + _shimmer.value * 2, 0),
                    colors: [kCosmicTeal, Color(0xFF00D4B8), kCosmicTeal],
                  ),
            boxShadow: widget.isSaving
                ? []
                : [
                    BoxShadow(
                      color: kCosmicTeal.withOpacity(
                        0.25 + _shimmer.value * 0.2,
                      ),
                      blurRadius: 20 + _shimmer.value * 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: Center(
            child: widget.isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kStarlightWhite,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(
                        Icons.satellite_alt_rounded,
                        color: kDeepSpace,
                        size: 19,
                      ),
                      SizedBox(width: 10),
                      Text(
                        "TRANSMIT TO LOG",
                        style: TextStyle(
                          color: kDeepSpace,
                          fontSize: 12,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w700,
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

class _MissionStatCell extends StatelessWidget {
  final String label, value;
  final Color color;
  const _MissionStatCell({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: kStarlightWhite.withOpacity(0.9),
              fontSize: 8,
              letterSpacing: 2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 30,
              fontWeight: FontWeight.w200,
              letterSpacing: 4,
            ),
          ),
        ],
      ),
    ),
  );
}

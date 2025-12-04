import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: const MonitorPastillero(),
    );
  }
}

class MonitorPastillero extends StatefulWidget {
  const MonitorPastillero({super.key});

  @override
  State<MonitorPastillero> createState() => _MonitorPastilleroState();
}

class _MonitorPastilleroState extends State<MonitorPastillero> {
  final DatabaseReference _dbRefHistorial = FirebaseDatabase.instance.ref('historial_tomas');
  final DatabaseReference _dbRefHorarios = FirebaseDatabase.instance.ref('horarios');
  
  List<Map<String, dynamic>> _horarios = [];
  List<Map<String, dynamic>> _historial = [];
  Timer? _timerVerificacion;
  
  // Variable para evitar spammear la alerta visual
  bool _alertaMostrada = false;

  @override
  void initState() {
    super.initState();
    // 1. Escuchar Historial (Lo que hace el ESP32)
    _dbRefHistorial.onValue.listen((event) {
      if (event.snapshot.value == null) return;
      final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
      setState(() {
        _historial.clear();
        data.forEach((key, value) {
          _historial.add(Map<String, dynamic>.from(value));
        });
      });
    });

    // 2. Escuchar Horarios (Lo que programamos nosotros)
    _dbRefHorarios.onValue.listen((event) {
      // SI ES NULL, SIGNIFICA QUE SE BORRÓ TODO -> LIMPIAMOS LA LISTA
      if (event.snapshot.value == null) {
        setState(() {
          _horarios.clear();
        });
        return;
      }
      
      final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
      setState(() {
        _horarios.clear();
        data.forEach((key, value) {
          final h = Map<String, dynamic>.from(value);
          h['key'] = key; 
          _horarios.add(h);
        });
      });
    });

    // 3. MOTOR DE VERIFICACIÓN (Corre cada 5 segundos)
    _timerVerificacion = Timer.periodic(const Duration(seconds: 5), (timer) {
      verificarOlvidos();
    });
  }

  @override
  void dispose() {
    _timerVerificacion?.cancel();
    super.dispose();
  }

  // --- LÓGICA CORE: ¿Se tomó la pastilla? ---
  void verificarOlvidos() {
    DateTime ahora = DateTime.now();
    bool hayPeligro = false;
    String mensajeError = "";
    
    // DEFINIR TOLERANCIA: ¿Cuánto tiempo le damos antes de considerar que se le olvidó?
    const int minutosTolerancia = 5; 

    for (var regla in _horarios) {
      // 1. Parsear hora programada
      int horaProg = int.parse(regla['hora'].split(":")[0]);
      int minProg = int.parse(regla['hora'].split(":")[1]);
      int cajonObjetivo = regla['cajon'];

      DateTime fechaProgramada = DateTime(ahora.year, ahora.month, ahora.day, horaProg, minProg);
      
      // Fecha Límite = Hora Programada + 15 minutos
      DateTime fechaLimite = fechaProgramada.add(const Duration(minutes: minutosTolerancia));

      // 2. Solo verificamos si YA PASÓ la tolerancia (Hora actual > Hora Programada + 15min)
      if (ahora.isAfter(fechaLimite)) {
        
        // Buscamos si hay un registro HOY entre la hora programada y ahora
        bool seTomo = false;
        
        for (var registro in _historial) {
          DateTime fechaRegistro = DateTime.fromMillisecondsSinceEpoch((registro['timestamp'] as int) * 1000);
          
          // Verificamos cumplimiento:
          // - Mismo cajón
          // - Mismo día
          // - La apertura ocurrió DESPUÉS de la hora programada original
          if (registro['cajon'] == cajonObjetivo && 
              fechaRegistro.year == ahora.year && 
              fechaRegistro.month == ahora.month &&
              fechaRegistro.day == ahora.day &&
              fechaRegistro.isAfter(fechaProgramada)) {
            seTomo = true;
            break;
          }
        }

        if (!seTomo) {
          hayPeligro = true;
          // Mostramos hace cuánto debió tomarla
          int minutosRetraso = ahora.difference(fechaProgramada).inMinutes;
          mensajeError = "¡ALERTA! El Cajón $cajonObjetivo tiene $minutosRetraso min de retraso.";
        }
      }
    }

    if (hayPeligro && !_alertaMostrada) {
      _mostrarAlertaVisual(mensajeError);
      _alertaMostrada = true;
    } else if (!hayPeligro) {
      _alertaMostrada = false;
    }
  }

  void _mostrarAlertaVisual(String mensaje) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("⚠️ PACIENTE EN RIESGO"),
        content: Text(mensaje),
        backgroundColor: Colors.red[50],
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ENTENDIDO", style: TextStyle(color: Colors.red)),
          )
        ],
      ),
    );
  }

  // Función para agregar horario (Simula la UI del doctor)
  void _agregarHorario() {
    TimeOfDay now = TimeOfDay.now();
    // Guardamos en Firebase
    _dbRefHorarios.push().set({
      "cajon": 1, // Por defecto cajón 1 para prueba rápida
      "hora": "${now.hour}:${now.minute}", // Hora actual para probar YA
      "descripcion": "Aspirina"
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Horario agregado: Cajón 1 AHORA (Espera 5 min para ver alerta si no abres)"))
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Control Pastillero")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _agregarHorario,
        label: const Text("Programar Cajón 1 (Ahora)"),
        icon: const Icon(Icons.alarm_add),
        backgroundColor: Colors.indigo,
      ),
      body: Column(
        children: [
          // SECCIÓN 1: HORARIOS PROGRAMADOS
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.grey[200],
            width: double.infinity,
            child: const Text("Horarios Programados (Debe tomarse):", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            flex: 1,
            child: ListView.builder(
              itemCount: _horarios.length,
              itemBuilder: (_, i) => ListTile(
                leading: const Icon(Icons.watch_later_outlined),
                title: Text("Cajón ${_horarios[i]['cajon']} - ${_horarios[i]['hora']}"),
                subtitle: Text(_horarios[i]['descripcion'] ?? ""),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _dbRefHorarios.child(_horarios[i]['key']).remove(),
                ),
              ),
            ),
          ),
          
          // SECCIÓN 2: HISTORIAL REAL
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.grey[200],
            width: double.infinity,
            child: const Text("Historial Real (Lo que hizo el paciente):", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            flex: 2,
            child: ListView.builder(
              itemCount: _historial.length, // Deberías ordenarlo como hicimos antes
              itemBuilder: (_, i) {
                // Ordenar visualmente inverso (chapuza rápida para demo)
                final evento = _historial[_historial.length - 1 - i]; 
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: Text("Cajón ${evento['cajon']} ABIERTO"),
                    subtitle: Text(evento['fecha_hora'] ?? ""),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
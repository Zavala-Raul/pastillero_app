import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; 

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
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
  
  bool _alertaMostrada = false;
  int _ultimoTimestampProcesado = 0;

  @override
  void initState() {
    super.initState();
    _ultimoTimestampProcesado = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
    
    _solicitarPermisosNotificacion();

    _dbRefHistorial.onValue.listen((event) {
      if (event.snapshot.value == null) {
        setState(() => _historial.clear());
        return;
      }
      final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
      final List<Map<String, dynamic>> tempList = [];
      
      data.forEach((key, value) {
        final reg = Map<String, dynamic>.from(value);
        if(!reg.containsKey('timestamp')) reg['timestamp'] = 0; 

        reg['key'] = key; 

        tempList.add(reg);
      });

      tempList.sort((a, b) {
        int tA = (a['timestamp'] as num).toInt();
        int tB = (b['timestamp'] as num).toInt();
        return tB.compareTo(tA); 
      });

      setState(() => _historial = tempList);

      if (tempList.isNotEmpty) {
        final ultimoEvento = tempList.first;
        int tsEvento = (ultimoEvento['timestamp'] as num).toInt();
        if (tsEvento > _ultimoTimestampProcesado) {
          _ultimoTimestampProcesado = tsEvento;
          Future.delayed(const Duration(milliseconds: 500), () {
            _preguntarConfirmacion(ultimoEvento);
          });
        }
      }
    });

    // 2. ESCUCHAR HORARIOS
    _dbRefHorarios.onValue.listen((event) {
      if (event.snapshot.value == null) {
        setState(() => _horarios.clear());
        return;
      }
      final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
      final List<Map<String, dynamic>> tempList = [];

      data.forEach((key, value) {
        final h = Map<String, dynamic>.from(value);
        h['key'] = key;
        if (h['status'] != 'completado') {
          tempList.add(h);
        }
      });

      tempList.sort((a, b) {
        String dtA = "${a['fecha']} ${a['hora']}";
        String dtB = "${b['fecha']} ${b['hora']}";
        return dtA.compareTo(dtB);
      });

      setState(() => _horarios = tempList);
    });

    _timerVerificacion = Timer.periodic(const Duration(seconds: 10), (timer) {
      verificarOlvidos();
    });
  }

  void _solicitarPermisosNotificacion() {
    flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  @override
  void dispose() {
    _timerVerificacion?.cancel();
    super.dispose();
  }

  // --- LANZAR NOTIFICACIÓN AL SISTEMA ---
  Future<void> _lanzarNotificacionSistema(String titulo, String cuerpo) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'canal_alertas_pastillero', // ID del canal
      'Alertas Críticas', // Nombre visible
      channelDescription: 'Notificaciones de olvido de medicación',
      importance: Importance.max,
      priority: Priority.high,
      color: Colors.red,
      playSound: true,
      enableVibration: true,
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails);
    
    await flutterLocalNotificationsPlugin.show(0, titulo, cuerpo, details);
  }

  void _preguntarConfirmacion(Map<String, dynamic> evento) {
    int cajonAbierto = evento['cajon'];
    String firebaseKey = evento['key'].toString(); 

    showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (ctx) => AlertDialog(
        title: Text("Se abrió el Cajón $cajonAbierto"),
        content: const Text("¿El paciente tomó su medicación?"),
        actions: [
          // BOTÓN NO
          TextButton(
            onPressed: () {
              _etiquetarHistorial(firebaseKey, "REVISIÓN");
              Navigator.pop(ctx);
            },
            child: const Text("NO (Solo revisar)"),
          ),
          // BOTÓN SÍ
          ElevatedButton(
            onPressed: () {
              _marcarComoCompletado(cajonAbierto);
              _etiquetarHistorial(firebaseKey, "TOMA REALIZADA");
              
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
            child: const Text("SÍ, TOMADA"),
          ),
        ],
      ),
    );
  }

  void _marcarComoCompletado(int cajon) {
    String hoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
    try {
      var tarea = _horarios.firstWhere((h) => h['cajon'] == cajon && h['fecha'] == hoy);
      _dbRefHorarios.child(tarea['key']).update({
        "status": "completado",
        "hora_toma_real": DateFormat('HH:mm').format(DateTime.now())
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("¡Dosis registrada!"), backgroundColor: Colors.green));
    } catch (e) {
      print("Apertura extra sin horario.");
    }
  }

  // --- LÓGICA DE ALERTAS ---
  void verificarOlvidos() {
    DateTime ahora = DateTime.now();
    bool hayPeligro = false;
    String mensajeError = "";
    const int minutosTolerancia = 2; 
    String hoyString = DateFormat('yyyy-MM-dd').format(ahora);

    for (var regla in _horarios) {
      if (regla['fecha'] != hoyString) continue;
      if (regla['status'] == 'completado') continue;

      int horaProg = int.parse(regla['hora'].split(":")[0]);
      int minProg = int.parse(regla['hora'].split(":")[1]);
      DateTime fechaProgramada = DateTime(ahora.year, ahora.month, ahora.day, horaProg, minProg);
      DateTime fechaLimite = fechaProgramada.add(const Duration(minutes: minutosTolerancia));

      if (ahora.isAfter(fechaLimite)) {
        hayPeligro = true;
        int minutosRetraso = ahora.difference(fechaProgramada).inMinutes;
        mensajeError = " ${regla['descripcion']} (Cajón ${regla['cajon']}) tiene $minutosRetraso min de retraso.";
      }
    }

    if (hayPeligro && !_alertaMostrada) {
      // 1. Mostrar Alerta en Pantalla (Visual)
      _mostrarAlertaVisual(mensajeError);
      
      // 2. LANZAR NOTIFICACIÓN AL SISTEMA (Sonido/Vibración)
      _lanzarNotificacionSistema("⚠️ ALERTA", mensajeError);

      _alertaMostrada = true;
    } else if (!hayPeligro) {
      _alertaMostrada = false;
    }
  }

  void _mostrarAlertaVisual(String mensaje) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning, color: Colors.red), SizedBox(width: 10), Text("RIESGO")]),
        content: Text(mensaje),
        backgroundColor: Colors.red[50],
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ENTENDIDO", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  void _mostrarDialogoAgregar() {
    int cajonSeleccionado = 1;
    int diasDuracion = 1;
    TimeOfDay horaSeleccionada = TimeOfDay.now();
    DateTime fechaInicio = DateTime.now();
    // CONTROLADOR PARA EL NOMBRE DEL MEDICAMENTO
    TextEditingController nombreController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Text("Programar Tratamiento"),
              content: SingleChildScrollView( // Scroll por si el teclado tapa
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // CAMPO DE TEXTO PERSONALIZADO
                    TextField(
                      controller: nombreController,
                      decoration: const InputDecoration(
                        labelText: "Nombre del Medicamento",
                        hintText: "Ej: Paracetamol",
                        icon: Icon(Icons.medication),
                      ),
                    ),
                    const SizedBox(height: 15),
                    
                    DropdownButtonFormField<int>(
                      value: cajonSeleccionado,
                      decoration: const InputDecoration(labelText: "Número de Cajón"),
                      items: List.generate(7, (index) => DropdownMenuItem(value: index + 1, child: Text("Cajón ${index + 1}"))),
                      onChanged: (v) => setModalState(() => cajonSeleccionado = v!),
                    ),
                    const SizedBox(height: 10),
                    ListTile(
                      title: Text("Hora: ${horaSeleccionada.format(context)}"),
                      trailing: const Icon(Icons.access_time),
                      onTap: () async {
                        final t = await showTimePicker(context: context, initialTime: horaSeleccionada);
                        if (t != null) setModalState(() => horaSeleccionada = t);
                      },
                    ),
                    ListTile(
                      title: Text("Inicia: ${DateFormat('dd/MM/yyyy').format(fechaInicio)}"),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final d = await showDatePicker(context: context, initialDate: fechaInicio, firstDate: DateTime.now(), lastDate: DateTime(2030));
                        if (d != null) setModalState(() => fechaInicio = d);
                      },
                    ),
                    Row(
                      children: [
                        const Text("Días: "),
                        IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => setModalState(() { if(diasDuracion > 1) diasDuracion--; })),
                        Text("$diasDuracion", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => setModalState(() => diasDuracion++)),
                      ],
                    )
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancelar")),
                ElevatedButton(
                  onPressed: () {
                    // Validamos que haya puesto nombre
                    String nombreFinal = nombreController.text.isEmpty ? "Medicamento General" : nombreController.text;
                    _guardarCampana(cajonSeleccionado, horaSeleccionada, fechaInicio, diasDuracion, nombreFinal);
                    Navigator.pop(context);
                  },
                  child: const Text("Guardar"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _guardarCampana(int cajon, TimeOfDay hora, DateTime inicio, int dias, String nombreMedicina) {
    final horaStr = "${hora.hour.toString().padLeft(2, '0')}:${hora.minute.toString().padLeft(2, '0')}";
    for (int i = 0; i < dias; i++) {
      DateTime fechaDosis = inicio.add(Duration(days: i));
      String fechaStr = DateFormat('yyyy-MM-dd').format(fechaDosis);
      _dbRefHorarios.push().set({
        "cajon": cajon,
        "fecha": fechaStr,
        "hora": horaStr,
        "descripcion": nombreMedicina, 
        "status": "pendiente"
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Se programó $nombreMedicina por $dias días.")));
  }

  void _etiquetarHistorial(String key, String tipoEvento) {
    _dbRefHistorial.child(key).update({
      "tipo_evento": tipoEvento 
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Control Pastillero")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _mostrarDialogoAgregar,
        label: const Text("Programar"),
        icon: const Icon(Icons.add_alarm),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.indigo[50],
            width: double.infinity,
            child: const Text("Próximas Dosis (Pendientes)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
          ),
          Expanded(
            flex: 1,
            child: _horarios.isEmpty 
              ? const Center(child: Text("¡Todo al día!")) 
              : ListView.builder(
                  itemCount: _horarios.length,
                  itemBuilder: (_, i) {
                    final item = _horarios[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.orange,
                          child: Text("${item['cajon']}", style: const TextStyle(color: Colors.white)),
                        ),
                        title: Text("${item['descripcion']}", style: const TextStyle(fontWeight: FontWeight.bold)), // NOMBRE GRANDE
                        subtitle: Text("Fecha: ${item['fecha']} - Hora: ${item['hora']}"),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.grey),
                          onPressed: () => _dbRefHorarios.child(item['key']).remove(),
                        ),
                      ),
                    );
                  },
                ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.green[50],
            width: double.infinity,
            child: const Text("Bitácora de Actividad", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
          ),
          Expanded(
            flex: 1,
            child: _historial.isEmpty
             ? const Center(child: Text("Sin actividad reciente"))
             : ListView.builder(
                itemCount: _historial.length,
                // DENTRO DEL ListView.builder DEL HISTORIAL
                itemBuilder: (_, i) {
                  final evento = _historial[i];
                  
                  // Determinamos el estilo según la etiqueta que pusimos
                  String tipo = evento['tipo_evento'] ?? "DETECTADO"; // Default si aún no respondes
                  bool esToma = tipo == "TOMA REALIZADA";
                  bool esRevision = tipo == "REVISIÓN";

                  return ListTile(
                    dense: true,
                    // Icono cambia: Pastilla (Verde) o Ojo/Herramienta (Gris)
                    leading: esToma 
                        ? const Icon(Icons.medication, color: Colors.green) 
                        : (esRevision ? const Icon(Icons.visibility, color: Colors.grey) : const Icon(Icons.help_outline, color: Colors.orange)),
                    
                    title: Text(
                      esToma ? "Toma de Medicamento (Cajón ${evento['cajon']})" : "Apertura de Revisión (Cajón ${evento['cajon']})",
                      style: TextStyle(
                        fontWeight: esToma ? FontWeight.bold : FontWeight.normal,
                        color: esToma ? Colors.black : Colors.grey[700]
                      )
                    ),
                    subtitle: Text("${evento['fecha_hora']} - Estado: $tipo"),
                  );
                },
              ),
          ),
        ],
      ),
    );
  }
}
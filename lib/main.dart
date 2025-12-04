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
      title: 'Mi Pastillero', 
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey[50],
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

  Future<void> _lanzarNotificacionSistema(String titulo, String cuerpo) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'canal_alertas_pastillero', 'Alertas Críticas',
      channelDescription: 'Notificaciones de olvido de medicación',
      importance: Importance.max, priority: Priority.high,
      color: Colors.red, playSound: true, enableVibration: true,
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(0, titulo, cuerpo, details);
  }

  void _etiquetarHistorial(String key, String tipoEvento) {
    _dbRefHistorial.child(key).update({"tipo_evento": tipoEvento});
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
          TextButton(
            onPressed: () {
              _etiquetarHistorial(firebaseKey, "REVISIÓN");
              Navigator.pop(ctx);
            },
            child: const Text("NO (Solo revisar)"),
          ),
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
      _mostrarAlertaVisual(mensajeError);
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
    int frecuenciaHoras = 24; 
    
    TimeOfDay horaSeleccionada = TimeOfDay.now();
    DateTime fechaInicio = DateTime.now();
    TextEditingController nombreController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Text("Programar Tratamiento"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nombreController,
                      decoration: const InputDecoration(labelText: "Nombre del Medicamento", hintText: "Ej: Antibiótico", icon: Icon(Icons.medication)),
                    ),
                    const SizedBox(height: 15),
                    
                    DropdownButtonFormField<int>(
                      value: cajonSeleccionado,
                      decoration: const InputDecoration(labelText: "Número de Cajón"),
                      items: List.generate(7, (index) => DropdownMenuItem(value: index + 1, child: Text("Cajón ${index + 1}"))),
                      onChanged: (v) => setModalState(() => cajonSeleccionado = v!),
                    ),
                    const SizedBox(height: 10),

                    DropdownButtonFormField<int>(
                      initialValue: frecuenciaHoras,
                      decoration: const InputDecoration(labelText: "Frecuencia", icon: Icon(Icons.timelapse)),
                      items: const [
                        DropdownMenuItem(value: 24, child: Text("Cada 24 horas (1 al día)")),
                        DropdownMenuItem(value: 12, child: Text("Cada 12 horas (2 al día)")),
                        DropdownMenuItem(value: 8, child: Text("Cada 8 horas (3 al día)")),
                        DropdownMenuItem(value: 6, child: Text("Cada 6 horas (4 al día)")),
                        DropdownMenuItem(value: 4, child: Text("Cada 4 horas (6 al día)")),
                      ],
                      onChanged: (v) => setModalState(() => frecuenciaHoras = v!),
                    ),
                    
                    ListTile(
                      title: Text("1ra Dosis: ${horaSeleccionada.format(context)}"),
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
                        const Text("Duración (Días): "),
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
                    String nombreFinal = nombreController.text.isEmpty ? "Medicamento General" : nombreController.text;
                    _guardarCampana(cajonSeleccionado, horaSeleccionada, fechaInicio, diasDuracion, nombreFinal, frecuenciaHoras);
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

  void _guardarCampana(int cajon, TimeOfDay hora, DateTime inicio, int dias, String nombreMedicina, int intervaloHoras) {
    DateTime fechaActual = DateTime(inicio.year, inicio.month, inicio.day, hora.hour, hora.minute);
    
    DateTime fechaFin = fechaActual.add(Duration(days: dias));

    int contadorDosis = 0;

    while (fechaActual.isBefore(fechaFin)) {
      
      String fechaStr = DateFormat('yyyy-MM-dd').format(fechaActual);
      String horaStr = DateFormat('HH:mm').format(fechaActual); 

      _dbRefHorarios.push().set({
        "cajon": cajon,
        "fecha": fechaStr,
        "hora": horaStr,
        "descripcion": nombreMedicina,
        "status": "pendiente"
      });

      fechaActual = fechaActual.add(Duration(hours: intervaloHoras));
      contadorDosis++;
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Se programaron $contadorDosis tomas de $nombreMedicina.")));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2, 
      child: Scaffold(
        appBar: AppBar(
          title: const Text("PillTakerZ"),
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              icon: const Icon(Icons.notifications_active),
              onPressed: () => _lanzarNotificacionSistema("Notificación", "Sistema de Notificaciones Activo"),
            )
          ],
          bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(icon: Icon(Icons.calendar_today), text: "Agenda"),
              Tab(icon: Icon(Icons.history_edu), text: "Bitácora"),
            ],
          ),
        ),
        
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _mostrarDialogoAgregar,
          label: const Text("Programar"),
          icon: const Icon(Icons.add_alarm),
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
        ),
        
        body: TabBarView(
          children: [
            _buildListaPendientes(),
            _buildListaHistorial(),
          ],
        ),
      ),
    );
  }

  Widget _buildListaPendientes() {
    if (_horarios.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 80, color: Colors.green),
            SizedBox(height: 10),
            Text("¡Todo al día!", style: TextStyle(fontSize: 20, color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: _horarios.length,
      itemBuilder: (_, i) {
        final item = _horarios[i];
        return Card(
          elevation: 2,
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.orange,
              child: Text("${item['cajon']}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            title: Text("${item['descripcion']}", style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Row(
              children: [
                const Icon(Icons.access_time, size: 16, color: Colors.grey),
                const SizedBox(width: 5),
                Text("${item['fecha']} a las ${item['hora']}"),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _dbRefHorarios.child(item['key']).remove(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildListaHistorial() {
    if (_historial.isEmpty) {
      return const Center(child: Text("Sin actividad reciente"));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: _historial.length,
      itemBuilder: (_, i) {
        final evento = _historial[i];
        
        String tipo = evento['tipo_evento'] ?? "DETECTADO"; 
        bool esToma = tipo == "TOMA REALIZADA";
        bool esRevision = tipo == "REVISIÓN";

        return Card(
          margin: const EdgeInsets.only(bottom: 5),
          child: ListTile(
            dense: true,
            leading: esToma 
                ? const Icon(Icons.medication, color: Colors.green) 
                : (esRevision ? const Icon(Icons.visibility, color: Colors.grey) : const Icon(Icons.help_outline, color: Colors.orange)),
            
            title: Text(
              esToma ? "Toma de Medicamento (Cajón ${evento['cajon']})" : "Apertura de Revisión (Cajón ${evento['cajon']})",
              style: TextStyle(fontWeight: esToma ? FontWeight.bold : FontWeight.normal)
            ),
            subtitle: Text("${evento['fecha_hora']} - Estado: $tipo"),
          ),
        );
      },
    );
  }
}
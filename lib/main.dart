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
      home: Scaffold(
        appBar: AppBar(title: const Text("Monitor Pastillero")),
        body: const HistorialList(),
      ),
    );
  }
}

class HistorialList extends StatefulWidget {
  const HistorialList({super.key});

  @override
  State<HistorialList> createState() => _HistorialListState();
}

class _HistorialListState extends State<HistorialList> {
  // REFERENCIA DIRECTA SIN FILTROS (Para evitar el crash de Java)
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref('historial_tomas');

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      // AQUÍ ESTÁ EL CAMBIO: Quitamos orderBy... y limitTo...
      // Escuchamos todo y filtramos en el teléfono.
      stream: _dbRef.onValue,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
          // Conversión segura de datos
          final data = Map<dynamic, dynamic>.from(
              snapshot.data!.snapshot.value as Map);
          
          final List<Map<String, dynamic>> items = [];
          
          data.forEach((key, value) {
            final evento = Map<String, dynamic>.from(value);
            // Aseguramos que el timestamp se lea como número, sea int o long
            if (!evento.containsKey('timestamp')) {
               evento['timestamp'] = 0;
            }
            items.add(evento);
          });

          // ORDENAMIENTO EN DART (Seguro)
          // Ordenamos del más reciente al más antiguo
          items.sort((a, b) {
            final tA = (a['timestamp'] as num).toInt();
            final tB = (b['timestamp'] as num).toInt();
            return tB.compareTo(tA);
          });

          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final evento = items[index];
              return Card(
                elevation: 3,
                color: Colors.blue[50],
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: ListTile(
                  leading: const Icon(Icons.medication, color: Colors.blue, size: 40),
                  title: Text(
                    "Cajón ${evento['cajon']}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Estado: ${evento['estado']}"),
                      Text("Hora: ${evento['fecha_hora']}", 
                           style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    ],
                  ),
                  isThreeLine: true,
                ),
              );
            },
          );
        }
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox, size: 50, color: Colors.grey),
              Text("No hay registros aún."),
            ],
          ),
        );
      },
    );
  }
}
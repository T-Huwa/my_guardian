import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _darkMode = false;
  String _selectedLanguage = "English";
  final bool _bridgeConnected = true;
  final String _firmwareVersion = "v1.2.3";
  bool _autoSyncEnabled = true;

  PermissionStatus? _contactPermissionStatus;

  final BluetoothClassic _bluetooth = BluetoothClassic();
  final List<Device> _foundDevices = [];
  bool _isScanning = false;
  Device? _connectedDevice;

  @override
  void initState() {
    super.initState();
    _checkContactPermission();
    _initBluetooth();
  }

  Future<void> _initBluetooth() async {
    // Set up bluetooth event listeners
    _bluetooth.onDeviceDiscovered().listen((device) {
      setState(() {
        if (!_foundDevices.any((d) => d.address == device.address)) {
          _foundDevices.add(device);
        }
      });
    });

    // _bluetooth.onDeviceDisconnected().listen((device) {
    //   setState(() {
    //     if (_connectedDevice?.address == device.address) {
    //       _connectedDevice = null;
    //     }
    //   });
    //   ScaffoldMessenger.of(context).showSnackBar(
    //     SnackBar(
    //       content: Text("Disconnected from ${device.name ?? 'Unknown Device'}"),
    //     ),
    //   );
    // });
  }

  Future<void> _checkContactPermission() async {
    final status = await Permission.contacts.status;
    setState(() {
      _contactPermissionStatus = status;
    });
  }

  Future<void> _scanForBluetoothDevices() async {
    //Request Bluetooth permissions
    var bluetoothStatus = await Permission.bluetooth.request();
    var bluetoothConnectStatus = await Permission.bluetoothConnect.request();
    var bluetoothScanStatus = await Permission.bluetoothScan.request();

    if (!bluetoothStatus.isGranted ||
        !bluetoothConnectStatus.isGranted ||
        !bluetoothScanStatus.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bluetooth permissions are required")),
      );
      return;
    }

    setState(() {
      _foundDevices.clear();
      _isScanning = true;
    });

    try {
      // First, get bonded (paired) devices
      final bondedDevices = await _bluetooth.getPairedDevices();
      setState(() {
        _foundDevices.addAll(bondedDevices);
      });

      // Start discovery to find new devices
      await _bluetooth.startScan();

      // Stop discovery after 30 seconds
      Future.delayed(const Duration(seconds: 30), () {
        if (_isScanning) {
          _bluetooth.stopScan();
          setState(() {
            _isScanning = false;
          });
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error scanning devices: $e")));
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _stopScan() async {
    if (_isScanning) {
      await _bluetooth.stopScan();
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _connectToDevice(Device device) async {
    try {
      await _stopScan(); // Stop scanning before connecting
      await _bluetooth.connect(device.address, "10");
      // The connection status will be handled by the onDeviceConnected listener
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Connection failed: $e")));
    }
  }

  Future<void> _disconnectDevice() async {
    if (_connectedDevice != null) {
      try {
        await _bluetooth.disconnect();
        // The disconnection status will be handled by the onDeviceDisconnected listener
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Disconnection failed: $e")));
      }
    }
  }

  void _showEmergencyContactOptions() async {
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.contacts),
              title: const Text("Choose from Contacts"),
              onTap: () async {
                Navigator.pop(context);
                await _pickContactFromPhone();
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_add),
              title: const Text("Enter Manually"),
              onTap: () {
                Navigator.pop(context);
                _showManualContactDialog();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickContactFromPhone() async {
    await _checkContactPermission(); // await FlutterContacts.requestPermission() Refresh permission state display

    if (_contactPermissionStatus!.isGranted) {
      final contact = await FlutterContacts.openExternalPick();
      if (contact != null && contact.phones.isNotEmpty) {
        final name = contact.displayName;
        final phone = contact.phones.first.number;
        await _saveEmergencyContact(name, phone);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Contacts permission is required"),
          action: SnackBarAction(label: "Settings", onPressed: openAppSettings),
        ),
      );
      return;
    }
  }

  void _showManualContactDialog() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text("Enter Contact"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: "Name"),
              ),
              TextField(
                controller: phoneController,
                decoration: const InputDecoration(labelText: "Phone"),
                keyboardType: TextInputType.phone,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final phone = phoneController.text.trim();

                if (name.isNotEmpty && phone.isNotEmpty) {
                  Navigator.pop(context);
                  await _saveEmergencyContact(name, phone);
                }
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveEmergencyContact(String name, String phone) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final contactData = {
      'name': name,
      'phone': phone,
      'addedAt': FieldValue.serverTimestamp(),
    };

    try {
      await FirebaseFirestore.instance
          .collection('profile')
          .doc(user.email)
          .collection('emergencyContacts')
          .add(contactData);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Emergency contact saved")));
      _fetchEmergencyContacts;
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Failed to save contact: $e")));
    }
  }

  Future<QuerySnapshot> _fetchEmergencyContacts() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception("Not logged in");

    // Make sure this path matches where you're saving contacts
    return FirebaseFirestore.instance
        .collection('profile')
        .doc(user.email)
        .collection('emergencyContacts')
        .orderBy('addedAt', descending: true)
        .get();
  }

  Future<void> _deleteContact(String contactId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception("Not logged in");
    await FirebaseFirestore.instance
        .collection('profile')
        .doc(user.email)
        .collection('emergencyContacts')
        .doc(contactId)
        .delete();

    setState(() {}); // Refresh UI
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Contact deleted")));
  }

  @override
  void dispose() {
    _stopScan();
    // Clean up any listeners or connections
    if (_connectedDevice != null) {
      _disconnectDevice();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: const Text("Settings", style: TextStyle(color: Colors.white)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: 270,
              child: Image.asset(
                "assets/images/settings.png",
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 20),
            const SettingsHeader(title: "User Settings"),
            SettingsTile(
              icon: Icons.notifications,
              title: "Notifications",
              trailing: Switch(
                activeTrackColor: Colors.green,
                inactiveTrackColor: Colors.green[50],
                value: _notificationsEnabled,
                onChanged: (value) {
                  setState(() {
                    _notificationsEnabled = value;
                  });
                },
              ),
            ),
            SettingsTile(
              icon: Icons.dark_mode,
              title: "Dark Mode",
              trailing: Switch(
                activeTrackColor: Colors.green,
                inactiveTrackColor: Colors.green[50],
                value: _darkMode,
                onChanged: (value) {
                  setState(() {
                    _darkMode = value;
                  });
                },
              ),
            ),
            SettingsTile(
              icon: Icons.language,
              title: "Language",
              trailing: DropdownButton<String>(
                value: _selectedLanguage,
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedLanguage = newValue!;
                  });
                },
                items:
                    [
                      "English",
                      "Chichewa",
                      "Tumbuka",
                    ].map<DropdownMenuItem<String>>((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
              ),
            ),
            const SizedBox(height: 20),
            const SettingsHeader(title: "Bridge State Settings"),
            SettingsTile(
              icon: Icons.wifi,
              title: "Connection Status",
              trailing: Text(
                _bridgeConnected ? "Connected" : "Disconnected",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _bridgeConnected ? Colors.green : Colors.red,
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.system_update,
              title: "Firmware Version",
              trailing: Text(
                _firmwareVersion,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            SettingsTile(
              icon: Icons.sync,
              title: "Auto Sync",
              trailing: Switch(
                activeTrackColor: Colors.green,
                inactiveTrackColor: Colors.green[50],
                value: _autoSyncEnabled,
                onChanged: (value) {
                  setState(() {
                    _autoSyncEnabled = value;
                  });
                },
              ),
            ),
            const SizedBox(height: 20),
            const SettingsHeader(title: "Emergency Contact"),
            SettingsTile(
              icon: Icons.contact_phone,
              title: "Manage Emergency Contact",
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: _showEmergencyContactOptions,
                child: const Text("Add"),
              ),
            ),
            if (_contactPermissionStatus != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.privacy_tip, color: Colors.green),
                    const SizedBox(width: 8),
                    Text(
                      "Contact Permission: ${_contactPermissionStatus!.isGranted
                          ? "Granted"
                          : _contactPermissionStatus!.isDenied
                          ? "Denied"
                          : "Restricted"}",
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            FutureBuilder<QuerySnapshot>(
              future: _fetchEmergencyContacts(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator();
                } else if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text("No emergency contacts added."),
                  );
                } else {
                  final contacts = snapshot.data!.docs;

                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final contact = contacts[index];
                      final name = contact['name'];
                      final phone = contact['phone'];

                      return ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(name),
                        subtitle: Text(phone),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _deleteContact(contact.id),
                        ),
                      );
                    },
                  );
                }
              },
            ),
            const SettingsHeader(title: "Bluetooth"),
            SettingsTile(
              icon: Icons.bluetooth_searching,
              title: "Scan for Devices",
              trailing: ElevatedButton(
                onPressed: _isScanning ? null : _scanForBluetoothDevices,
                child: Text(_isScanning ? "Scanning..." : "Scan"),
              ),
            ),

            if (_foundDevices.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:
                      _foundDevices.map((device) {
                        return ListTile(
                          leading: const Icon(Icons.bluetooth),
                          title: Text(device.name ?? 'Unknown'),
                          subtitle: Text(device.address),
                        );
                      }).toList(),
                ),
              ),

            if (_connectedDevice != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green[100],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.green),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bluetooth_connected, color: Colors.green),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _connectedDevice!.name ?? "Unknown Device",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(_connectedDevice!.address),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _disconnectDevice,
                    ),
                  ],
                ),
              ),
            ..._foundDevices.map(
              (device) => ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(device.name ?? "Unknown Device"),
                subtitle: Text(device.address),
                trailing:
                    (_connectedDevice?.address == device.address)
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(Icons.circle_outlined),
                onTap: () async {
                  if (_connectedDevice?.address != device.address) {
                    await _connectToDevice(device);
                  } else {
                    await _disconnectDevice();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsHeader extends StatelessWidget {
  final String title;
  const SettingsHeader({required this.title, super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.blueGrey,
          ),
        ),
      ),
    );
  }
}

// General Settings Tile
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget trailing;

  const SettingsTile({
    required this.icon,
    required this.title,
    required this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.green),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

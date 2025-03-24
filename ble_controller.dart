import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BleController extends GetxController {
  final RxList<ScanResult> scanResults = <ScanResult>[].obs;
  final RxBool isConnected = false.obs;
  final RxBool isScanning = false.obs;
  BluetoothDevice? connectedDevice;
  Function(String)? onDataReceived;
  String? lastConnectedDeviceId;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _scanTimer;

  @override
  void onInit() {
    super.onInit();
    initializeBluetooth();
    _loadLastConnectedDevice();
  }

  /// Initialize Bluetooth and auto-connect if needed
  Future<void> initializeBluetooth() async {
    FlutterBluePlus.setLogLevel(LogLevel.verbose);

    FlutterBluePlus.state.listen((state) {
      if (state == BluetoothState.on) {
        startAutoReconnect(); // ✅ Start auto-reconnect when Bluetooth is on
      }
    });
  }

  /// Load last connected device from storage and attempt reconnection
  Future<void> _loadLastConnectedDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    lastConnectedDeviceId = prefs.getString('lastConnectedDeviceId');
    if (lastConnectedDeviceId != null) {
      startAutoReconnect(); // ✅ Start auto-reconnect when app starts
    }
  }

  /// Scan for BLE devices
  Future<void> scanDevices() async {
    if (isScanning.value) return;

    scanResults.clear();
    isScanning.value = true;

    try {
      await FlutterBluePlus.stopScan();
      FlutterBluePlus.scanResults.listen((results) {
        scanResults.assignAll(results);
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    } catch (e) {
      print("Scan Error: $e");
    } finally {
      isScanning.value = false;
    }
  }

  /// Auto-reconnect to device when it is back in range
  void startAutoReconnect() {
    _scanTimer?.cancel(); // Cancel previous timer if any
    _scanTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!isConnected.value) {
        await scanDevices();
        await Future.delayed(const Duration(seconds: 2)); // Allow scan time

        for (var result in scanResults) {
          if (result.device.id.id == lastConnectedDeviceId) {
            print("Auto-reconnecting to ${result.device.name}");
            await connectToDevice(result.device);
            break;
          }
        }
      }
    });
  }

  /// Connect to a BLE device
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      connectedDevice = device;
      isConnected.value = true;

      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastConnectedDeviceId', device.id.id);

      await Future.delayed(const Duration(milliseconds: 500));
      _setupNotifications(device);
      _monitorConnectionState(device);
    } catch (e) {
      print("Connection Error: $e");
    }
  }

  /// Monitor connection state
  void _monitorConnectionState(BluetoothDevice device) {
    _connectionSubscription?.cancel();

    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        isConnected.value = true;
      } else {
        isConnected.value = false;
        print("Device disconnected. Auto-reconnect will try again.");
      }
    });
  }

  /// Setup notifications for receiving BLE data
  Future<void> _setupNotifications(BluetoothDevice device) async {
    var services = await device.discoverServices();
    for (var service in services) {
      for (var characteristic in service.characteristics) {
        if (characteristic.properties.notify) {
          await characteristic.setNotifyValue(true);
          characteristic.value.listen((value) {
            _handleIncomingData(value);
          });
        }
      }
    }
  }

  /// Handle incoming BLE data
  void _handleIncomingData(List<int> value) {
    String newData = utf8.decode(value);
    if (onDataReceived != null) {
      onDataReceived!(newData);
    }
  }

  /// Disconnect from device
  Future<void> disconnectDevice() async {
    await connectedDevice?.disconnect();
    isConnected.value = false;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('lastConnectedDeviceId');
    _connectionSubscription?.cancel();
    _scanTimer?.cancel();
  }

  /// Forget the last connected device
  Future<void> forgetDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('lastConnectedDeviceId');
    lastConnectedDeviceId = null;
    print("Device forgotten. Auto-connect disabled.");
    _scanTimer?.cancel();
  }

  /// Set callback for received BLE data
  void setOnDataReceived(Function(String) callback) {
    onDataReceived = callback;
  }

  /// Send data to BLE device
  Future<void> sendData(String data) async {
    if (connectedDevice == null) return;

    var services = await connectedDevice!.discoverServices();
    for (var service in services) {
      for (var characteristic in service.characteristics) {
        if (characteristic.properties.write) {
          List<int> bytes = utf8.encode(data);
          await characteristic.write(bytes);
          return;
        }
      }
    }
  }

  @override
  void onClose() {
    _connectionSubscription?.cancel();
    _scanTimer?.cancel();
    super.onClose();
  }
}

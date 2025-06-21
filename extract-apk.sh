import sys
import subprocess
import os
import time
import re
import zipfile

# --- START PyQt6 Dependency Check ---
try:
    from PyQt6.QtWidgets import (
        QApplication, QWidget, QVBoxLayout, QHBoxLayout,
        QPushButton, QLineEdit, QLabel, QTextEdit,
        QFileDialog, QMessageBox, QGridLayout, QComboBox,
        QSpacerItem, QSizePolicy, QProgressBar, QCheckBox,
        QDialog
    )
    from PyQt6.QtGui import QFont, QColor, QTextCharFormat, QTextCursor, QPainter, QBrush, QPen, QGuiApplication
    from PyQt6.QtCore import Qt, QThread, pyqtSignal, QTimer, QSize
except ImportError:
    # If PyQt6 is not found, try to display a basic message and exit
    # This part needs to be very basic as PyQt6 itself might not be available
    print("Error: PyQt6 is not installed.")
    print("Please install PyQt6 using: pip install PyQt6")
    print("Exiting application.")
    sys.exit(1)
# --- END PyQt6 Dependency Check ---


# QThread class to run ADB commands in the background
class WorkerThread(QThread):
    finished = pyqtSignal(str, str, int, float)
    error = pyqtSignal(str)
    progress_update = pyqtSignal(int)
    log_message = pyqtSignal(str, str) # Used for internal debug logs, not for public UI logs

    def __init__(self, command, measure_time=False, is_download=False):
        super().__init__()
        self.command = command
        self.measure_time = measure_time
        self.is_download = is_download
        self.process = None # Initialize process as None

    def run(self):
        start_time = time.time()
        try:
            # This log_message is for internal worker only, not displayed in the initial UI dialog
            # self.log_message.emit(f"Executing command: {self.command}", "purple")
            self.process = subprocess.Popen(
                self.command,
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding='utf-8',
                bufsize=1
            )

            stdout_lines = []
            stderr_lines = []

            stdout_data, stderr_data = self.process.communicate()

            stdout_lines.append(stdout_data)
            stderr_lines.append(stderr_data)

            end_time = time.time()
            time_taken = end_time - start_time

            self.finished.emit("".join(stdout_lines), "".join(stderr_lines), self.process.returncode, time_taken)

        except FileNotFoundError:
            self.error.emit("Error: ADB command not found. Make sure ADB is installed and in your PATH.")
        except Exception as e:
            self.error.emit(f"An error occurred while running the command: {e}")
        finally:
            if self.process and self.process.poll() is None:
                self.process.kill()

# Class for blinking connection indicator
class ConnectionIndicator(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedSize(QSize(10, 10))
        self._color = QColor("red")
        self.animation_timer = QTimer(self)
        self.animation_timer.timeout.connect(self._animate_dot)
        self.current_alpha = 255
        self.is_on = True

        self.set_status("disconnected")

    def set_status(self, status):
        self.animation_timer.stop()
        self.is_on = True
        self.current_alpha = 255

        if status == "connected":
            self._color = QColor("#00ff00")
            self.animation_timer.start(1000) # Blinks slowly every 1 second
        elif status == "connecting":
            self._color = QColor("#ffa500")
            self.animation_timer.start(400)
        elif status == "disconnected":
            self._color = QColor("#d6184f")
            self.animation_timer.start(200)
        self.update()

    def _animate_dot(self):
        self.is_on = not self.is_on
        self.current_alpha = 255 if self.is_on else 0
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        color_with_alpha = QColor(self._color)
        color_with_alpha.setAlpha(self.current_alpha)

        painter.setBrush(QBrush(color_with_alpha))
        painter.setPen(QPen(Qt.PenStyle.NoPen))
        painter.drawEllipse(0, 0, self.width(), self.height())

# Initial Connection Dialog for ADB
class InitialConnectionDialog(QDialog):
    # Signal to be emitted to MainWindow when ADB connection is successful
    connection_successful = pyqtSignal()
    # Signal to notify MainWindow about ADB check status (is_connected, device_id)
    adb_status_checked = pyqtSignal(bool, str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Waiting for ADB Connection")

        # Calculate screen center for dialog positioning
        screen = QGuiApplication.primaryScreen().geometry()
        dialog_width = 450
        dialog_height = 250
        x = (screen.width() - dialog_width) // 2
        y = (screen.height() - dialog_height) // 2
        self.setGeometry(x, y, dialog_width, dialog_height)

        self.setModal(True)

        self.adb_available = False
        self.check_timer = QTimer(self) # Timer for automatic checks
        self.check_timer.setInterval(2000) # Check every 2 seconds
        self.check_timer.timeout.connect(self._check_adb_connection)

        # Timer for loading dots animation
        self.loading_dot_timer = QTimer(self)
        self.loading_dot_timer.setInterval(500) # Update dots every 500ms
        self.loading_dot_timer.timeout.connect(self._animate_loading_dots)
        self.dot_count = 0

        self.init_ui()
        self._check_adb_availability_initial() # Initial ADB availability check

        self.worker = None

    def init_ui(self):
        layout = QVBoxLayout()
        self.setLayout(layout)

        # Add a stretch to push content downwards, ensuring vertical centering
        layout.addStretch(1)

        # Replace long instructions with dynamic status message
        self.status_label = QLabel(
            "<h1>Waiting for ADB Device Connection...</h1>"
            "<p>Ensure your Android device is connected via <b>USB</b> "
            "and <b>USB Debugging</b> is enabled.</p>"
            "<p>There might be an authorization prompt on your device. Please accept it.</p>"
        )
        self.status_label.setWordWrap(True)
        self.status_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.status_label)

        # Replaced QProgressBar with QLabel for dot animation
        self.loading_dot_label = QLabel("Connecting.")
        self.loading_dot_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.loading_dot_label.setFont(QFont("Arial", 12)) # Set a font for visibility
        layout.addWidget(self.loading_dot_label)

        # Add another stretch to push content upwards, ensuring vertical centering
        layout.addStretch(1)

    def _animate_loading_dots(self):
        # Animate the loading dots
        self.dot_count = (self.dot_count + 1) % 4
        self.loading_dot_label.setText("Connecting" + "." * self.dot_count)


    def update_status_message(self, text, color="black"):
        # Function to update status message in QLabel
        self.status_label.setText(text)
        # Add color style if needed (not directly supported by QLabel HTML)
        if color == "red":
            self.status_label.setStyleSheet("color: red;")
        elif color == "#00ff00" or color == "#c0ffee":
            self.status_label.setStyleSheet("color: #008000;") # Green
        elif color == "orange":
            self.status_label.setStyleSheet("color: orange;")
        else:
            self.status_label.setStyleSheet("") # Reset style


    def _check_adb_availability_initial(self):
        # Checks if ADB command is available on the system (only once at the beginning)
        try:
            subprocess.run("adb version", shell=True, capture_output=True, check=True)
            self.adb_available = True
            self.update_status_message("<h1>Waiting for ADB Device Connection...</h1>"
                                       "<p>Ensure your Android device is connected via <b>USB</b> "
                                       "and <b>USB Debugging</b> is enabled.</p>"
                                       "<p>There might be an authorization prompt on your device. Please accept it.</p>", "#00ff00")
            self.check_timer.start() # Start timer if ADB is available
            self.loading_dot_timer.start() # Start loading dots animation
        except (subprocess.CalledProcessError, FileNotFoundError):
            self.adb_available = False
            self.update_status_message("<h1>CRITICAL: ADB Not Found!</h1>"
                                       "<p>ADB command not found. This application requires ADB.</p>"
                                       "<p>Please install <b>Android SDK Platform-Tools</b> and ensure ADB is in your system PATH.</p>"
                                       "<p>Download from: <a href='https://developer.android.com/studio/releases/platform-tools'>developer.android.com/studio/releases/platform-tools</a></p>", "red")
            self.check_timer.stop() # Stop timer if ADB is not available
            self.loading_dot_timer.stop() # Stop loading dots animation
            # Consider showing a critical QMessageBox here and exiting if no ADB
            QMessageBox.critical(self, "ADB Not Found",
                                 "ADB command not found. This application will close. Please install Android SDK Platform-Tools.")
            sys.exit(1) # Exit application

    def _check_adb_connection(self):
        # Starts the ADB connection check process
        if not self.adb_available:
            # If ADB is not available, the message has already been displayed in _check_adb_availability_initial
            return

        # Use WorkerThread to prevent UI freeze
        self.worker = WorkerThread("adb devices")
        self.worker.finished.connect(self._on_adb_check_finished)
        self.worker.error.connect(self._on_worker_error)
        # No need to connect log_message from worker to initial UI dialog anymore

        self.worker.start()
        self.loading_dot_timer.start() # Ensure dots animation is running during check

    def _on_adb_check_finished(self, stdout, stderr, returncode, time_taken):
        self.worker = None # Remove worker reference after completion
        self.loading_dot_timer.stop() # Stop dots animation

        is_connected_and_authorized = False
        device_id_detected = "" # Initialize with empty string

        # Look for lines indicating connected and 'device' status
        # Prioritize Wi-Fi connection if available
        wifi_device_status_match = re.search(r"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d{1,5})\s+device", stdout)
        usb_device_status_match = re.search(r"^[a-zA-Z0-9]+\s+device", stdout, re.MULTILINE)

        if wifi_device_status_match:
            device_id_detected = wifi_device_status_match.group(1)
            is_connected_and_authorized = True
        elif usb_device_status_match:
            device_id_detected = usb_device_status_match.group(0).split()[0]
            is_connected_and_authorized = True

        if is_connected_and_authorized:
            self.update_status_message(f"<h1>ADB Connection Successful!</h1><p>Device detected and authorized: <b>{device_id_detected}</b></p><p>Main GUI will load shortly.</p>", "#00ff00")
            self.adb_status_checked.emit(True, device_id_detected)
            self.check_timer.stop() # Stop timer
            QTimer.singleShot(1000, self.accept) # Close dialog after 1 second
        else:
            self.update_status_message("<h1>Waiting for ADB Device Connection...</h1>"
                                       "<p>No device detected or unauthorized.</p>"
                                       "<p>Ensure device is connected via <b>USB</b>, <b>USB Debugging</b> is active, and authorization has been accepted.</p>", "orange")
            # If not connected or unauthorized, send empty ID
            self.adb_status_checked.emit(False, "")
            self.loading_dot_timer.start() # Restart dots if still waiting
            # Timer will automatically trigger next check

    def _on_worker_error(self, message):
        self.worker = None
        self.loading_dot_timer.stop() # Stop dots animation on error
        self.update_status_message(f"<h1>ERROR!</h1><p>{message}</p><p>Retrying...</p>", "red")
        self.adb_status_checked.emit(False, "") # Send empty ID if there's an error
        # Timer will automatically trigger next check

class MainWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("APK Extractor (via ADB)")
        self.setGeometry(100, 100, 1200, 600)

        self.adb_connected = False
        self.connected_device_id = None # New attribute to store connected device ID
        self.apk_available = False
        self.last_extracted_apk_filename = None
        self.all_apk_paths = []
        self.debug_mode = False
        self.adb_available = False # Set by initial dialog
        self.total_download_size = 0
        self.current_local_download_path = None

        # Initialize attributes to store worker thread references
        self.tcpip_worker = None
        self.connect_ip_worker = None
        self.devices_worker = None
        self.disconnect_worker = None
        self.transfer_worker = None
        self.execute_worker = None
        self.apk_list_worker = None
        self.get_size_worker = None
        self.download_worker = None

        # Display initial connection dialog
        self.initial_dialog = InitialConnectionDialog(self)
        self.hide()

        # Initialize connection_indicator here, before dialog is executed
        # so that the object exists when _handle_initial_adb_status is called.
        self.connection_indicator = ConnectionIndicator(self)

        # adb_status_checked signal from dialog will trigger _set_initial_adb_connected_state
        self.initial_dialog.adb_status_checked.connect(self._set_initial_adb_connected_state)

        if self.initial_dialog.exec() == QDialog.DialogCode.Accepted:
            # If dialog closes with accept(), it means ADB connection was successful
            self.adb_available = True # Ensure this status is updated
            self.init_ui() # UI elements created here
            # After UI is created, call _update_button_states and _update_input_field_states
            # to reflect the initial connection status already stored in self.adb_connected
            self._update_input_field_states()
            self._update_button_states()
            self.show()
        else:
            # If dialog is rejected (closed without successful connection, or ADB not found), exit application
            sys.exit(0)

        self.download_progress_timer = QTimer(self)
        self.download_progress_timer.setInterval(200)
        self.download_progress_timer.timeout.connect(self._update_download_progress)

    def _set_initial_adb_connected_state(self, is_connected, device_id):
        """
        Slot to receive initial ADB connection status from InitialConnectionDialog.
        Only sets internal status; does not directly update UI elements.
        UI updates will occur after init_ui() is called and finishes.
        """
        self.adb_connected = is_connected
        self.connected_device_id = device_id if is_connected else None
        if self.debug_mode:
            self.display_log(f"DEBUG: Initial ADB state received: {is_connected}, Device ID: {device_id}", "blue")


    def show_adb_warning_popup(self):
        # This popup is now replaced by InitialConnectionDialog
        pass

    def init_ui(self):
        main_grid_layout = QGridLayout()
        self.setLayout(main_grid_layout)

        # connection_indicator already initialized in __init__
        # Just add it to the layout here
        indicator_layout = QHBoxLayout()
        indicator_layout.addSpacerItem(QSpacerItem(0, 0, QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed))
        indicator_layout.addWidget(self.connection_indicator)
        main_grid_layout.addLayout(indicator_layout, 0, 1, Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignRight)

        # --- Left Section: Configuration (25% width) ---
        left_panel_layout = QVBoxLayout()
        main_grid_layout.addLayout(left_panel_layout, 1, 0, 1, 1)

        # ADB Configuration Section
        adb_config_group_layout = QGridLayout()
        left_panel_layout.addLayout(adb_config_group_layout)

        row = 0
        adb_config_group_layout.addWidget(QLabel("<h2>ADB Configuration</h2>"), row, 0, 1, 2, alignment=Qt.AlignmentFlag.AlignCenter)
        row += 1

        # Connection Type Dropdown
        adb_config_group_layout.addWidget(QLabel("Connection Type:"), row, 0)
        self.connection_type_combo = QComboBox()
        self.connection_type_combo.addItem("USB")
        self.connection_type_combo.addItem("Wi-Fi")
        self.connection_type_combo.currentIndexChanged.connect(self._update_connection_type_ui)
        self.connection_type_combo.setFixedWidth(270) # Set fixed width for alignment
        adb_config_group_layout.addWidget(self.connection_type_combo, row, 1)
        row += 1

        # IP Input for Wi-Fi
        wifi_ip_layout = QHBoxLayout()
        wifi_ip_layout.addWidget(QLabel("Device IP:"))
        wifi_ip_layout.addStretch(1) # ADD THIS LINE TO PUSH IP INPUT TO THE RIGHT
        self.ip_input = QLineEdit("192.168.1.XX:5555")
        self.ip_input.setFixedWidth(270) # Set fixed width for alignment
        wifi_ip_layout.addWidget(self.ip_input)
        # Remove or comment out the old addStretch if it exists after self.ip_input
        # wifi_ip_layout.addStretch(1) # This line was pushing the input to the left
        adb_config_group_layout.addLayout(wifi_ip_layout, row, 0, 1, 2)
        row += 1

        # Connect and Disconnect Buttons (moved here to be always visible)
        connect_disconnect_layout = QHBoxLayout()
        self.connect_btn = QPushButton("Connect ADB")
        self.connect_btn.clicked.connect(self.test_adb_connection)
        connect_disconnect_layout.addWidget(self.connect_btn)

        self.disconnect_btn = QPushButton("Disconnect ADB")
        self.disconnect_btn.clicked.connect(self.disconnect_adb)
        connect_disconnect_layout.addWidget(self.disconnect_btn)
        adb_config_group_layout.addLayout(connect_disconnect_layout, row, 0, 1, 2)
        row += 1

        # NEW: Enable Wi-Fi ADB (via USB) button
        self.enable_tcpip_btn = QPushButton("Enable Wi-Fi ADB (USB)")
        self.enable_tcpip_btn.clicked.connect(self._enable_adb_tcpip)
        adb_config_group_layout.addWidget(self.enable_tcpip_btn, row, 0, 1, 2)
        row += 1


        # Debug Mode Checkbox
        self.debug_checkbox = QCheckBox("Verbose")
        self.debug_checkbox.setChecked(self.debug_mode)
        self.debug_checkbox.toggled.connect(self._toggle_debug_mode)
        adb_config_group_layout.addWidget(self.debug_checkbox, row, 0, 1, 2, alignment=Qt.AlignmentFlag.AlignLeft)
        row += 1

        # Environment Settings Section (Script and APK Path)
        path_group_layout = QGridLayout()
        left_panel_layout.addLayout(path_group_layout)

        path_group_layout.addWidget(QLabel("<h2>Environment Settings</h2>"), 0, 0, 1, 3, alignment=Qt.AlignmentFlag.AlignCenter)

        path_group_layout.addWidget(QLabel("Mechanism :"), 1, 0)
        self.script_mechanism_combo = QComboBox()
        self.script_mechanism_combo.addItem("Push Script & Run")
        self.script_mechanism_combo.addItem("Run Device Script")
        self.script_mechanism_combo.currentIndexChanged.connect(self._update_script_mechanism_ui)
        path_group_layout.addWidget(self.script_mechanism_combo, 1, 1, 1, 2)

        self.local_script_widgets = QWidget()
        local_script_h_layout = QHBoxLayout()
        local_script_h_layout.setContentsMargins(0, 0, 0, 0)
        self.local_script_widgets.setLayout(local_script_h_layout)

        self.local_script_path_input = QLineEdit()
        local_script_h_layout.addWidget(self.local_script_path_input)
        self.browse_local_script_btn = QPushButton("Select File...")
        self.browse_local_script_btn.clicked.connect(self.browse_local_script_path)
        local_script_h_layout.addWidget(self.browse_local_script_btn)

        path_group_layout.addWidget(QLabel("Extractor Script (SH):"), 2, 0)
        path_group_layout.addWidget(self.local_script_widgets, 2, 1, 1, 2)

        current_row = 3
        self.remote_script_label = QLabel("extract-apk.sh Script (on Android):")
        path_group_layout.addWidget(self.remote_script_label, current_row, 0, 1, 3)
        current_row += 1
        self.remote_script_path_input = QLineEdit()
        self.remote_script_path_input.setPlaceholderText("/data/local/tmp/extract-apk.sh")
        path_group_layout.addWidget(self.remote_script_path_input, current_row, 0, 1, 3)

        current_row += 1
        path_group_layout.addWidget(QLabel("Application APK Path (on Android):"), current_row, 0, 1, 3)
        current_row += 1

        self.apk_filter_input = QLineEdit()
        self.apk_filter_input.setPlaceholderText("Filter APKs...")
        self.apk_filter_input.textChanged.connect(self._filter_apk_paths)
        path_group_layout.addWidget(self.apk_filter_input, current_row, 0, 1, 3)
        current_row += 1

        apk_path_controls_layout = QHBoxLayout()
        self.apk_path_combo = QComboBox()
        self.apk_path_combo.setEditable(False)
        self.apk_path_combo.setPlaceholderText("/data/app/com.example.app-XYZ/base.apk")
        apk_path_controls_layout.addWidget(self.apk_path_combo)

        self.refresh_apk_btn = QPushButton("Refresh")
        self.refresh_apk_btn.clicked.connect(self.fetch_apk_paths)
        apk_path_controls_layout.addWidget(self.refresh_apk_btn)

        path_group_layout.addLayout(apk_path_controls_layout, current_row, 0, 1, 3)

        action_button_layout = QHBoxLayout()
        left_panel_layout.addLayout(action_button_layout)

        self.transfer_script_btn = QPushButton("Start")
        self.transfer_script_btn.clicked.connect(self.transfer_and_run_script)
        action_button_layout.addWidget(self.transfer_script_btn)

        self.run_script_btn = QPushButton("Start")
        self.run_script_btn.clicked.connect(self.run_script_on_android)
        action_button_layout.addWidget(self.run_script_btn)

        self.download_apk_btn = QPushButton("Download APK")
        self.download_apk_btn.clicked.connect(self.download_apk_from_android)
        action_button_layout.addWidget(self.download_apk_btn)

        left_panel_layout.addStretch(1)

        # --- Right Section: Log Output Area (75% width) ---
        right_panel_layout = QVBoxLayout()
        main_grid_layout.addLayout(right_panel_layout, 1, 1, 1, 1)

        right_panel_layout.addWidget(QLabel("<h2></h2>"))
        self.log_output = QTextEdit()
        self.log_output.setReadOnly(True)
        self.log_output.setFont(QFont("Monospace", 10))
        right_panel_layout.addWidget(self.log_output)

        self.download_progress_bar = QProgressBar(self)
        self.download_progress_bar.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.download_progress_bar.setFormat("Downloading: %p%")
        self.download_progress_bar.setVisible(False)
        right_panel_layout.addWidget(self.download_progress_bar)

        # Change column proportions to 20% for left and 80% for right
        main_grid_layout.setColumnStretch(0, 20)
        main_grid_layout.setColumnStretch(1, 80)

        # Initialize UI based on default selection (USB)
        self._update_connection_type_ui(self.connection_type_combo.currentIndex())
        self._update_script_mechanism_ui(self.script_mechanism_combo.currentIndex())
        # Call _update_button_states() here to set initial button states
        self._update_button_states()
        self._update_input_field_states()

    def _update_connection_type_ui(self, index):
        # Index 0 is "USB", Index 1 is "Wi-Fi"
        if index == 0:  # USB selected
            # Hide IP input for Wi-Fi
            self.ip_input.setVisible(False)
            self.ip_input.clear() # Clear IP text when switching to USB
            self.enable_tcpip_btn.setVisible(False) # Hide enable TCP/IP button
        else:  # Wi-Fi selected
            self.ip_input.setVisible(True)
            self.enable_tcpip_btn.setVisible(True) # Show enable TCP/IP button
        self._update_button_states()
        self._update_input_field_states()

    def _update_button_states(self):
        is_adb_ready = self.adb_connected
        connection_type = self.connection_type_combo.currentText()

        # Update connection indicator status
        if is_adb_ready:
            self.connection_indicator.set_status("connected")
        else:
            # Check if IP is entered for Wi-Fi, for "connecting" status
            if connection_type == "Wi-Fi" and self.ip_input.text().strip() and self.connect_ip_worker is not None and self.connect_ip_worker.isRunning():
                self.connection_indicator.set_status("connecting")
            elif connection_type == "USB" and self.devices_worker is not None and self.devices_worker.isRunning():
                self.connection_indicator.set_status("connecting")
            else:
                self.connection_indicator.set_status("disconnected")

        # Connect ADB button status: enabled if ADB IS NOT connected
        self.connect_btn.setEnabled(not is_adb_ready)
        # Disconnect ADB button status: enabled if ADB IS connected
        self.disconnect_btn.setEnabled(is_adb_ready)

        # Enable TCP/IP button status: enabled if Wi-Fi is selected AND not connected
        self.enable_tcpip_btn.setEnabled(connection_type == "Wi-Fi" and not is_adb_ready)


        current_mechanism_index = self.script_mechanism_combo.currentIndex()

        if current_mechanism_index == 0: # Push Script & Run
            self.transfer_script_btn.setEnabled(is_adb_ready)
            self.run_script_btn.setEnabled(False)
            self.download_apk_btn.setEnabled(is_adb_ready and self.apk_available and self.last_extracted_apk_filename is not None)
        else: # Run Device Script
            self.transfer_script_btn.setEnabled(False)
            self.run_script_btn.setEnabled(is_adb_ready)
            self.download_apk_btn.setEnabled(is_adb_ready and self.apk_available and self.last_extracted_apk_filename is not None)

        self.refresh_apk_btn.setEnabled(is_adb_ready)
        self._update_input_field_states()

    def _update_input_field_states(self):
        is_connected = self.adb_connected
        connection_type = self.connection_type_combo.currentText()

        # Read-only for Wi-Fi only when connected
        self.ip_input.setReadOnly(is_connected and connection_type == "Wi-Fi")
        self.remote_script_path_input.setReadOnly(is_connected)
        self.apk_filter_input.setEnabled(True)

    def disconnect_adb(self):
        # For USB, this just resets internal status and UI
        # For Wi-Fi, this runs 'adb disconnect <ip>'
        connection_type = self.connection_type_combo.currentText()
        ip = self.ip_input.text().strip()

        if connection_type == "Wi-Fi" and ip:
            disconnect_command = f"adb disconnect {ip}"
            self.display_log(f"Attempting to disconnect ADB from {ip}...", "#00face")
            # Execute disconnect command in worker thread and store its reference
            self.disconnect_worker = WorkerThread(disconnect_command)
            self.disconnect_worker.finished.connect(
                lambda stdout, stderr, returncode, time_taken:
                    self._on_disconnect_finished(stdout, stderr, returncode, time_taken)
            )
            self.disconnect_worker.error.connect(self.on_worker_error)
            self.disconnect_worker.log_message.connect(self._handle_worker_log_message)
            self.disconnect_worker.start()
        else:
            # If USB or no IP for Wi-Fi, just reset status
            self.display_log("ADB disconnection (for USB or no IP) initiated.", "#00face")
            self._reset_adb_state_and_ui()

    def _on_disconnect_finished(self, stdout, stderr, returncode, time_taken):
        if returncode == 0:
            self.display_log("ADB device successfully disconnected.", "#c0ffee")
        else:
            self.display_log(f"Failed to disconnect ADB: {stderr}", "red")
        # Reset ADB status and update UI after disconnect command finishes
        self._reset_adb_state_and_ui()
        # Remove reference to worker after completion for garbage collection
        self.disconnect_worker = None

    def _reset_adb_state_and_ui(self):
        # This function is responsible for resetting internal status and updating the UI
        # It will NOT close the application.
        self.adb_connected = False
        self.connected_device_id = None # Reset connected device ID
        self.apk_available = False
        self.last_extracted_apk_filename = None
        self.connection_indicator.set_status("disconnected")
        self.display_log("ADB disconnected.", "#00face")
        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)

        # --- START FIX: Clear APK dropdown and data on disconnect ---
        self.all_apk_paths = []
        self.apk_path_combo.clear()
        self.apk_path_combo.setPlaceholderText("/data/app/com.example.app-XYZ/base.apk")
        # --- END FIX ---

        self._update_button_states()
        self._update_input_field_states()

    def _check_adb_availability(self):
        # This function is now only used for logging in Mainwindow after initial_dialog completes
        try:
            subprocess.run("adb version", shell=True, capture_output=True, check=True)
            self.adb_available = True
            self.display_log("ADB found. Ready to communicate with Android devices.", "#c0ffee")
        except (subprocess.CalledProcessError, FileNotFoundError):
            self.adb_available = False
            self.display_log("Warning: ADB not found. Please install Android SDK Platform-Tools and ensure ADB is in your PATH.", "orange")
            self.display_log("Download: developer.android.com/studio/releases/platform-tools", "orange")


    def _update_script_mechanism_ui(self, index):
        if index == 0:  # Push Script & Run
            self.local_script_widgets.setVisible(True)
            self.transfer_script_btn.setVisible(True)
            self.run_script_btn.setVisible(False)
            self.remote_script_label.setText("Target Storage Path:")
            self.remote_script_path_input.setPlaceholderText("/data/local/tmp/extract-apk.sh")
            if self.remote_script_path_input.text() == "/data/local/tmp/extract-apk.sh" or \
               self.remote_script_path_input.text() == "/data/local/tmp/extract-apk.sh" or \
               not self.remote_script_path_input.text():
                self.remote_script_path_input.setText("/data/local/tmp/extract-apk.sh")
        else:  # Run Device Script
            self.local_script_widgets.setVisible(False)
            self.transfer_script_btn.setVisible(False)
            self.run_script_btn.setVisible(True)
            self.remote_script_label.setText("extract-apk.sh Script (on Android):")
            self.remote_script_path_input.setPlaceholderText("/data/local/tmp/extract-apk.sh")
            self.remote_script_path_input.setText("/data/local/tmp/extract-apk.sh")
            self.local_script_path_input.clear()
        self._update_button_states()

    def browse_local_script_path(self):
        file_name, _ = QFileDialog.getOpenFileName(self, "Select extract-apk.sh Script", "", "Shell Scripts (*.sh);;All Files (*)")
        if file_name:
            self.local_script_path_input.setText(file_name)
            script_name = os.path.basename(file_name)
            self.remote_script_path_input.setText(f"/data/local/tmp/{script_name}")

    def display_log(self, text, color="black"):
        cursor = self.log_output.textCursor()
        cursor.movePosition(QTextCursor.MoveOperation.End)
        format = QTextCharFormat()
        format.setForeground(QColor(color))
        cursor.insertText(text + "\n", format)
        self.log_output.setTextCursor(cursor)
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())

    def _handle_worker_log_message(self, message, color):
        if self.debug_mode or not message.startswith("Executing command:"):
            self.display_log(message, color)

    def _toggle_debug_mode(self, checked):
        self.debug_mode = checked
        if self.debug_mode:
            self.display_log("Debug mode enabled (showing all commands).", "dark#c0ffee")
        else:
            self.display_log("Debug mode disabled (logs will be cleaner).", "dark#c0ffee")

    def _build_adb_command(self, action, ip=None, local_path=None, remote_path=None, apk_path_or_package_name=None):
        base_command = ""
        # Use self.connected_device_id if available
        device_target_arg = ""
        if self.connected_device_id:
            device_target_arg = f"-s {self.connected_device_id}"
        # If not Wi-Fi and self.connected_device_id is not set, but an IP is provided (e.g., for tcpip), use that
        elif ip and action != "test_connection_devices": # adb devices should not have -s
            device_target_arg = f"-s {ip}"

        if action == "connect_tcpip":
            # adb tcpip command should NOT use -s <ip>, it configures the *currently connected USB device*.
            # It should ideally use the currently detected USB device ID, but `adb tcpip` implicitly uses it.
            # So, we don't prepend -s for this specific command.
            return f"adb tcpip {ip.split(':')[-1] if ':' in ip else '5555'}"
        elif action == "connect_ip":
            return f"adb connect {ip}"
        elif action == "test_connection_devices":
            return f"adb devices" # No -s here, as we are listing all devices
        elif action == "transfer":
            base_command = f"adb {device_target_arg} push \"{local_path}\" \"{remote_path}\""
        elif action == "execute":
            base_command = f"adb {device_target_arg} shell \"chmod +x '{remote_path}' && '{remote_path}' '{apk_path_or_package_name}'\""
        elif action == "list_apks":
            base_command = f"adb {device_target_arg} shell \"pm list packages -f\""
        elif action == "get_apk_size": # New command to get APK size
            base_command = f"adb {device_target_arg} shell \"stat -c %s '{apk_path_or_package_name}'\""
        elif action == "download_apk":
            base_command = f"adb {device_target_arg} pull \"{apk_path_or_package_name}\" \"{local_path}\""

        return base_command

    def _enable_adb_tcpip(self):
        """
        Handles the 'Enable Wi-Fi ADB (USB)' button click.
        This function will check for a USB device and then run 'adb tcpip'.
        """
        if not self.adb_available:
            QMessageBox.critical(self, "Error", "ADB command not found. Please ensure ADB is installed and in your PATH.")
            return

        self.display_log("Attempting to enable ADB over TCP/IP. Checking for USB device...", "#00face")
        self._disable_all_buttons_and_inputs_during_operation()
        self.connection_indicator.set_status("connecting")

        # First, check for a USB device to enable TCP/IP
        self.check_usb_for_tcpip_worker = WorkerThread("adb devices")
        self.check_usb_for_tcpip_worker.finished.connect(
            lambda stdout, stderr, returncode, time_taken:
                self._on_usb_check_for_tcpip_for_tcpip_finished(stdout, stderr, returncode, time_taken, self.ip_input.text().strip())
        )
        self.check_usb_for_tcpip_worker.error.connect(self.on_worker_error)
        self.check_usb_for_tcpip_worker.start()

    def _on_usb_check_for_tcpip_for_tcpip_finished(self, stdout, stderr, returncode, time_taken, ip):
        self.check_usb_for_tcpip_worker = None # Clear worker reference

        usb_device_found = False
        for line in stdout.splitlines():
            # Check for any device listed as 'device' (connected and authorized)
            if re.search(r"^[a-zA-Z0-9.:]+\s+device", line) and not re.search(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d{1,5}\s+device", line):
                # Ensure it's a USB device, not a Wi-Fi connected one already
                usb_device_found = True
                break

        if usb_device_found:
            self.display_log("USB device detected. Proceeding to enable ADB over TCP/IP.", "#c0ffee")
            # Proceed with Step 1: adb tcpip
            self.tcpip_worker = WorkerThread(self._build_adb_command("connect_tcpip", ip=ip), measure_time=True)
            self.display_log(f"Running 'adb tcpip' command...", "#00face")
            self.tcpip_worker.finished.connect(self._on_tcpip_finished)
            self.tcpip_worker.error.connect(self.on_worker_error)
            self.tcpip_worker.log_message.connect(self._handle_worker_log_message)
            self.tcpip_worker.start()
        else:
            self.display_log("No USB device found. To enable ADB over TCP/IP, you must first connect your Android device via USB and ensure USB Debugging is enabled and authorized.", "red")
            self.display_log("Please connect via USB first, then click 'Enable Wi-Fi ADB (USB)' again.", "orange")
            self._re_enable_all_buttons_and_inputs_after_operation()
            self.connection_indicator.set_status("disconnected")


    def test_adb_connection(self):
        if not self.adb_available:
            QMessageBox.critical(self, "Error", "ADB command not found. Please ensure ADB is installed and in your PATH.")
            return

        connection_type = self.connection_type_combo.currentText()
        ip = self.ip_input.text().strip()

        if connection_type == "Wi-Fi" and not ip:
            QMessageBox.warning(self, "Input Error", "Please fill in Device IP for Wi-Fi connection.")
            return

        self._disable_all_buttons_and_inputs_during_operation()
        self.apk_available = False
        self.last_extracted_apk_filename = None
        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)
        self.connection_indicator.set_status("connecting")

        if connection_type == "USB":
            self.display_log("Attempting to connect via USB. Checking connected devices...", "#00face")
            self._start_adb_devices_check()
        else: # Wi-Fi
            # For Wi-Fi, directly attempt 'adb connect IP'
            self.display_log(f"Attempting to connect to {ip} via Wi-Fi...", "#00face")
            self.connect_ip_worker = WorkerThread(self._build_adb_command("connect_ip", ip=ip), measure_time=True)
            self.connect_ip_worker.finished.connect(self._on_connect_ip_finished)
            self.connect_ip_worker.error.connect(self.on_worker_error)
            self.connect_ip_worker.log_message.connect(self._handle_worker_log_message)
            self.connect_ip_worker.start()


    def _on_tcpip_finished(self, stdout, stderr, returncode, time_taken):
        self.tcpip_worker = None # Remove reference after completion
        if returncode == 0 or "already in tcpip mode" in stdout.lower() or "restarting in TCP mode" in stdout.lower():
            self.display_log(f"ADB over TCP/IP enabled. (Time: {time_taken:.2f}s)", "#c0ffee")
            self.display_log("You can now disconnect USB and attempt Wi-Fi connection using 'Connect ADB' button.", "orange")
        else:
            self.display_log(f"Failed to enable ADB over TCP/IP: {stderr}", "red")
            self.display_log("Please ensure your device is connected via USB and USB Debugging is enabled.", "orange")
        self._re_enable_all_buttons_and_inputs_after_operation()
        self.connection_indicator.set_status("disconnected") # Since we're just enabling, not connecting fully

    def _on_connect_ip_finished(self, stdout, stderr, returncode, time_taken):
        self.connect_ip_worker = None # Remove reference after completion
        if returncode == 0 and ("connected to" in stdout.lower() or "already connected" in stdout.lower()):
            self.display_log(f"Successfully connected to {self.ip_input.text().strip()} via IP. (Time: {time_taken:.2f}s)", "#c0ffee")
            self._start_adb_devices_check() # Final check with adb devices to get device ID
        else:
            self.display_log(f"Failed to connect to {self.ip_input.text().strip()} via IP: {stderr}", "red")
            self.display_log("This usually means the device is not listening on that IP/port, or a firewall is blocking.", "red")
            self.display_log("If you haven't already, please connect your device via USB and click 'Enable Wi-Fi ADB (USB)' first.", "orange")
            self._re_enable_all_buttons_and_inputs_after_operation()
            self.connection_indicator.set_status("disconnected")

    def _start_adb_devices_check(self):
        # Use regular adb devices command, without -s, to get a list of all devices
        self.devices_worker = WorkerThread("adb devices", measure_time=True)
        self.devices_worker.finished.connect(self.on_test_connection_finished)
        self.devices_worker.error.connect(self.on_worker_error)
        self.devices_worker.log_message.connect(self._handle_worker_log_message)
        self.devices_worker.start()

    def on_test_connection_finished(self, stdout, stderr, returncode, time_taken):
        self.devices_worker = None # Remove reference after completion
        self.display_log("Transmission Status", "#f7f5de")
        if stdout:
            self.display_log(stdout, "black")
        if stderr:
            self.display_log(stderr, "red")

        is_connected_and_authorized = False
        device_id_detected = None

        # Look for devices with 'device' status (connected and authorized)
        # Prioritize IP if available, then USB
        for line in stdout.splitlines():
            wifi_match = re.search(r"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d{1,5})\s+device", line)
            usb_match = re.search(r"^[a-zA-Z0-9]+\s+device", line)

            if wifi_match:
                device_id_detected = wifi_match.group(1)
                is_connected_and_authorized = True
                break
            elif usb_match:
                device_id_detected = usb_match.group(0).split()[0]
                is_connected_and_authorized = True
                break

        # Check for "unauthorized" or "offline" status
        if not is_connected_and_authorized:
            for line in stdout.splitlines():
                unauthorized_match = re.search(r"(\S+)\s+unauthorized", line)
                offline_match = re.search(r"(\S+)\s+offline", line)

                if unauthorized_match:
                    self.display_log(f"Device {unauthorized_match.group(1)} unauthorized. Please accept the RSA fingerprint on your Android device.", "red")
                    break
                elif offline_match:
                    self.display_log(f"Device {offline_match.group(1)} offline. Please check status/network.", "red")
                    break

        if is_connected_and_authorized:
            self.display_log(f"ADB device online and authorized! ID: {device_id_detected} (Time: {time_taken:.2f}s)", "#c0ffee")
            self.adb_connected = True
            self.connected_device_id = device_id_detected # Store device ID
            self.apk_available = False
            self.last_extracted_apk_filename = None
            self.connection_indicator.set_status("connected")
            # If connected via Wi-Fi, set ip_input to detected IP if not already set
            if self.connection_type_combo.currentText() == "Wi-Fi" and device_id_detected and ":" in device_id_detected:
                self.ip_input.setText(device_id_detected)
        else:
            self.display_log(f"ADB device not found or unauthorized (code {returncode}).", "red")
            self.display_log("Please ensure USB Debugging is enabled and authorized on your device.", "red")
            self.adb_connected = False
            self.connected_device_id = None # Ensure ID perangkat direset
            self.apk_available = False
            self.last_extracted_apk_filename = None
            self.connection_indicator.set_status("disconnected")

        self._re_enable_all_buttons_and_inputs_after_operation()

    def _disable_all_buttons_and_inputs_during_operation(self):
        # Disable all action buttons
        self.connect_btn.setEnabled(False)
        self.disconnect_btn.setEnabled(False)
        self.transfer_script_btn.setEnabled(False)
        self.run_script_btn.setEnabled(False)
        self.refresh_apk_btn.setEnabled(False)
        self.download_apk_btn.setEnabled(False)
        self.enable_tcpip_btn.setEnabled(False) # Disable new button too
        # Make relevant inputs read-only
        self.ip_input.setReadOnly(True)
        self.remote_script_path_input.setReadOnly(True)
        self.local_script_path_input.setReadOnly(True)
        self.browse_local_script_btn.setEnabled(False)
        self.apk_filter_input.setEnabled(False)
        self.connection_type_combo.setEnabled(False)
        self.script_mechanism_combo.setEnabled(False)

    def _re_enable_all_buttons_and_inputs_after_operation(self):
        self._update_button_states() # This will re-enable most buttons
        self._update_input_field_states() # This will re-enable relevant inputs
        self.local_script_path_input.setReadOnly(False) # Ensure local script path is editable
        self.browse_local_script_btn.setEnabled(True)
        self.apk_filter_input.setEnabled(True) # Ensure filter is always active
        self.connection_type_combo.setEnabled(True)
        self.script_mechanism_combo.setEnabled(True)


    def transfer_and_run_script(self):
        if not self.adb_connected:
            QMessageBox.warning(self, "Connection Error", "Please connect to ADB first.")
            return
        if self.script_mechanism_combo.currentIndex() != 0:
            QMessageBox.warning(self, "Input Error", "This button is only for 'Push Script & Run' mechanism.")
            return

        local_script = self.local_script_path_input.text()

        remote_script = self.remote_script_path_input.text().strip()
        apk_path_or_package_name = self.apk_path_combo.currentData() # Use currentData() for actual APK path

        if not local_script or not os.path.exists(local_script):
            QMessageBox.warning(self, "Input Error", "Please select a valid extract-apk.sh script on your laptop.")
            return
        # Check IP only if connection type is Wi-Fi and not yet connected (or connected_device_id not set)
        if self.connection_type_combo.currentText() == "Wi-Fi" and not self.connected_device_id:
             QMessageBox.warning(self, "Input Error", "Please fill in Device IP.")
             return
        if not remote_script or not apk_path_or_package_name:
            QMessageBox.warning(self, "Input Error", "Please fill in Android Script Path and APK Path.")
            return

        self._disable_all_buttons_and_inputs_during_operation()
        self.apk_available = False
        self.last_extracted_apk_filename = None
        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)

        adb_push_command = self._build_adb_command(
            "transfer", local_path=local_script, remote_path=remote_script
        )

        self.display_log(f"Attempting to push script: {adb_push_command}", "#00face")

        self.transfer_worker = WorkerThread(adb_push_command)
        self.transfer_worker.finished.connect(
            lambda stdout, stderr, returncode, time_taken:
                self._on_transfer_finished_and_then_run(
                    stdout, stderr, returncode, time_taken,
                    remote_script, apk_path_or_package_name
                )
        )
        self.transfer_worker.error.connect(self.on_worker_error)
        self.transfer_worker.log_message.connect(self._handle_worker_log_message)
        self.transfer_worker.start()

    def _on_transfer_finished_and_then_run(self, stdout, stderr, returncode, time_taken, remote_script, apk_path_or_package_name):
        self.display_log("Script Push Result", "#f7f5de")
        if stdout:
            self.display_log(stdout, "black")
        if stderr:
            self.display_log(stderr, "red")

        self.display_log(f"DEBUG: Push return code: {returncode}", "blue")
        self.display_log(f"DEBUG: Push stdout (raw): '{stdout}'", "blue")


        if returncode == 0:
            self.display_log("Script pushed successfully!", "#c0ffee")
            self.transfer_worker = None # Remove reference after completion
            adb_execute_command = self._build_adb_command(
                "execute", remote_path=remote_script, apk_path_or_package_name=apk_path_or_package_name
            )

            self.display_log(f"Attempting to run script on Android: {adb_execute_command}", "#00face")

            self.execute_worker = WorkerThread(adb_execute_command)
            self.execute_worker.finished.connect(self.on_execute_finished)
            self.execute_worker.error.connect(self.on_worker_error)
            self.execute_worker.log_message.connect(self._handle_worker_log_message)
            self.execute_worker.start()
        else:
            self.display_log(f"Script push failed with code {returncode}.", "red")
            self.display_log("Please ensure ADB is connected and the remote path exists and is writable.", "red")
            if "Permission denied" in stderr:
                self.display_log("Permission denied on device. Check remote script path permissions.", "red")
            elif "No such file or directory" in stderr:
                self.display_log("Remote destination directory on Android not found. Check Android script path.", "red")
            self._re_enable_all_buttons_and_inputs_after_operation()
            self.transfer_worker = None # Remove reference if push fails


    def fetch_apk_paths(self):
        if not self.adb_connected:
            QMessageBox.warning(self, "Connection Error", "Please connect to ADB first.")
            return

        # No need to pass IP to build_adb_command anymore as it uses self.connected_device_id
        adb_list_command = self._build_adb_command("list_apks")

        self._disable_all_buttons_and_inputs_during_operation()
        self.apk_available = False
        self.last_extracted_apk_filename = None
        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)

        self.display_log(f"Attempting to retrieve APK list from Android...", "#00face")

        self.apk_list_worker = WorkerThread(adb_list_command)
        self.apk_list_worker.finished.connect(self.on_apk_paths_fetched)
        self.apk_list_worker.error.connect(self.on_worker_error)
        self.apk_list_worker.log_message.connect(self._handle_worker_log_message)
        self.apk_list_worker.start()

    def on_apk_paths_fetched(self, stdout, stderr, returncode, time_taken):
        self.apk_list_worker = None # Remove reference after completion
        self.display_log("APK List Output", "#869ef8")
        if stdout:
            self.display_log(stdout, "#f7f5de")
        if stderr:
            self.display_log(stderr, "red")

        if returncode == 0:
            self.display_log("APK list successfully retrieved!", "#c0ffee")
            self.all_apk_paths = []
            self.apk_path_combo.clear()

            for line in stdout.splitlines():
                match = re.search(r"package:(.+)=(.+)", line)
                if match:
                    package_name = match.group(1).strip()
                    apk_path = match.group(2).strip()
                    # Extract only filename for display
                    apk_filename = os.path.basename(apk_path)
                    # Display only APK filename for brevity
                    display_text = apk_filename
                    self.all_apk_paths.append((display_text, apk_path)) # Store as tuple (display_text, actual_path)
                    self.apk_path_combo.addItem(display_text, apk_path) # Add to dropdown, store actual path as data

            self.apk_path_combo.setEditable(False)
        else:
            self.display_log(f"Failed to retrieve APK list with code {returncode}.", "red")
            self.display_log("Please ensure ADB is connected and authorized on your device.", "red")
            if "Permission denied" in stderr or "error: device unauthorized" in stderr:
                self.display_log("Permission denied or device unauthorized. Accept the RSA fingerprint on your Android device.", "red")
            elif "not found" in stderr:
                self.display_log("`pm` command not found on device, or device not rooted/configured correctly.", "red")

        self._re_enable_all_buttons_and_inputs_after_operation()
        self.apk_path_combo.hidePopup()

    def _filter_apk_paths(self, text):
        self.apk_path_combo.blockSignals(True)
        self.apk_path_combo.clear()
        if text:
            filtered_data = []
            for display_filename, actual_apk_path_full in self.all_apk_paths:
                # Filter by displayed filename or full APK path
                if text.lower() in display_filename.lower() or text.lower() in actual_apk_path_full.lower():
                    filtered_data.append((display_filename, actual_apk_path_full))

            for display_text, apk_path in filtered_data:
                self.apk_path_combo.addItem(display_text, apk_path)
            if filtered_data:
                self.apk_path_combo.showPopup()
            else:
                self.apk_path_combo.hidePopup()
        else:
            for display_text, apk_path in self.all_apk_paths:
                self.apk_path_combo.addItem(display_text, apk_path)
            self.apk_path_combo.hidePopup()

        self.apk_path_combo.blockSignals(False)

    def run_script_on_android(self):
        if not self.adb_connected:
            QMessageBox.warning(self, "Connection Error", "Please connect to ADB first.")
            return
        if self.script_mechanism_combo.currentIndex() != 1:
            QMessageBox.warning(self, "Input Error", "This button is only for 'Run Device Script' mechanism.")
            return

        remote_script = self.remote_script_path_input.text().strip()
        apk_path_or_package_name = self.apk_path_combo.currentData()

        if not remote_script or not apk_path_or_package_name:
            QMessageBox.warning(self, "Input Error", "Please fill in Android Script Path and APK Path/Package Name.")
            return

        adb_execute_command = self._build_adb_command(
            "execute", remote_path=remote_script, apk_path_or_package_name=apk_path_or_package_name
        )

        self._disable_all_buttons_and_inputs_during_operation()
        self.apk_available = False
        self.last_extracted_apk_filename = None
        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)

        self.display_log(f"Attempting to run script on Android: {adb_execute_command}", "#00face")

        self.execute_worker = WorkerThread(adb_execute_command)
        self.execute_worker.finished.connect(self.on_execute_finished)
        self.execute_worker.error.connect(self.on_worker_error)
        self.execute_worker.log_message.connect(self._handle_worker_log_message)
        self.execute_worker.start()

    def on_execute_finished(self, stdout, stderr, returncode, time_taken):
        self.execute_worker = None # Remove reference after completion
        self.display_log("--- Script Execution Output ---", "#f7f5de")
        if stdout:
            self.display_log(stdout, "black")
        if stderr:
            self.display_log(stderr, "red")

        if returncode == 0:
            self.display_log("Script executed successfully on Android!", "#c0ffee")
            self.display_log("The .apk file should have been extracted to the location expected by the script.", "#c0ffee")
            self.apk_available = True

            match = re.search(r"APK Extracted: (.+\.apk)", stdout)
            if match:
                self.last_extracted_apk_filename = match.group(1).strip()
                self.display_log(f"APK filename detected: {self.last_extracted_apk_filename}", "#c0ffee")
            else:
                self.display_log("Warning: Could not automatically detect APK filename from script output. Please verify manually.", "orange")
                self.last_extracted_apk_filename = None
                self.apk_available = False
        else:
            self.display_log(f"Script execution failed with code {returncode}.", "red")
            self.display_log("Please check ADB connection, Android script path, and APK path/package name.", "red")
            if "Permission denied" in stderr:
                self.display_log("Permission denied. Check script file permissions on Android.", "red")
            elif "not found" in stderr:
                self.display_log("Required script or command not found on Android device.", "red")
            self.apk_available = False
            self.last_extracted_apk_filename = None

        self._re_enable_all_buttons_and_inputs_after_operation()

    def _process_multi_apk_download(self, downloaded_file_path):
        """
        Processes multi-part APKs downloaded (APKS, XAPK, APKM) to extract base.apk.
        """
        self.display_log(f"INFO: Detecting multi-part APK: {os.path.basename(downloaded_file_path)}", "blue")
        extracted_base_apk_path = None
        try:
            # Create a directory for extracted files next to the downloaded file
            extraction_dir = downloaded_file_path + "_extracted"
            os.makedirs(extraction_dir, exist_ok=True)
            self.display_log(f"INFO: Creating extraction directory: {extraction_dir}", "blue")

            with zipfile.ZipFile(downloaded_file_path, 'r') as zip_ref:
                # List all files inside the archive to find base.apk
                apk_files_in_archive = [f.filename for f in zip_ref.infolist() if f.filename.endswith('.apk')]

                base_apk_found = False
                for apk_in_archive in apk_files_in_archive:
                    # Look for base.apk (or other primary APK if base.apk is not present)
                    if os.path.basename(apk_in_archive) == "base.apk":
                        self.display_log(f"INFO: Extracting base.apk from {os.path.basename(downloaded_file_path)}...", "blue")
                        zip_ref.extract(apk_in_archive, extraction_dir)
                        extracted_base_apk_path = os.path.join(extraction_dir, apk_in_archive)
                        base_apk_found = True
                        break # base.apk found, no need to check further

                if base_apk_found:
                    self.display_log(f"SUCCESS: base.apk extracted to: {extracted_base_apk_path}", "#c0ffee")
                else:
                    self.display_log(f"WARNING: base.apk not found in {os.path.basename(downloaded_file_path)}. Extracted APKs: {', '.join(apk_files_in_archive)}", "orange")
                    self.display_log("Consider using SAI (Split APKs Installer) or similar tools to install this multi-part APK if base.apk is missing.", "orange")

        except zipfile.BadZipFile:
            self.display_log(f"ERROR: Downloaded file {os.path.basename(downloaded_file_path)} is not a valid ZIP/APK archive.", "red")
        except Exception as e:
            self.display_log(f"ERROR: Failed to process multi-part APK: {e}", "red")

        return extracted_base_apk_path

    def download_apk_from_android(self):
        if not self.adb_connected:
            QMessageBox.warning(self, "Connection Error", "Please connect to ADB first.")
            return
        if not self.apk_available or self.last_extracted_apk_filename is None:
            QMessageBox.warning(self, "APK Not Ready", "APK file not yet extracted or its filename could not be determined from the last operation.")
            return

        remote_apk_full_path = self.last_extracted_apk_filename

        # Get APK size from Android device first
        get_size_command = self._build_adb_command("get_apk_size", apk_path_or_package_name=remote_apk_full_path)
        self.display_log(f"Attempting to get remote APK size: {get_size_command}", "#00face")

        self._disable_all_buttons_and_inputs_during_operation()
        self.download_progress_bar.setVisible(True)
        self.download_progress_bar.setValue(0)

        self.get_size_worker = WorkerThread(get_size_command)
        self.get_size_worker.finished.connect(
            lambda stdout, stderr, returncode, time_taken:
                self._on_apk_size_fetched(stdout, stderr, returncode, time_taken, remote_apk_full_path)
        )
        self.get_size_worker.error.connect(self.on_worker_error)
        self.get_size_worker.log_message.connect(self._handle_worker_log_message)
        self.get_size_worker.start()

    def _on_apk_size_fetched(self, stdout, stderr, returncode, time_taken, remote_apk_full_path):
        self.get_size_worker = None # Remove reference after completion
        self.display_log("--- APK Size Output ---", "#f7f5de")
        if stdout:
            self.display_log(stdout, "black")
        if stderr:
            self.display_log(stderr, "red")

        if returncode == 0 and stdout.strip().isdigit():
            self.total_download_size = int(stdout.strip())
            self.display_log(f"Remote APK size: {self.total_download_size} bytes", "#c0ffee")

            # Continue with actual download process
            self._start_actual_apk_pull(remote_apk_full_path)
        else:
            self.display_log(f"Failed to get remote APK size (code {returncode}). Error: {stderr}", "red")
            self.display_log("Cannot proceed with download without knowing file size.", "red")
            self._re_enable_all_buttons_and_inputs_after_operation()
            self.download_progress_bar.setVisible(False)
            self.download_progress_bar.setValue(0)


    def _start_actual_apk_pull(self, remote_apk_full_path):
        # Get local save path from dialog
        default_filename = os.path.basename(remote_apk_full_path)
        local_save_path, _ = QFileDialog.getSaveFileName(self, "Save APK File", default_filename, "APK Files (*.apk);;All Files (*)")

        if not local_save_path:
            self.display_log("APK download cancelled by user.", "#f7f5de")
            self._re_enable_all_buttons_and_inputs_after_operation()
            self.download_progress_bar.setVisible(False)
            self.download_progress_bar.setValue(0)
            return

        self.current_local_download_path = local_save_path

        download_command = self._build_adb_command(
            "download_apk", apk_path_or_package_name=remote_apk_full_path, local_path=local_save_path
        )

        self.display_log(f"Attempting to download APK: {download_command}", "#00face")

        # Start progress timer
        self.download_progress_timer.start()

        self.download_worker = WorkerThread(download_command, is_download=True)
        self.download_worker.finished.connect(self.on_apk_download_finished)
        self.download_worker.error.connect(self.on_worker_error)
        self.download_worker.log_message.connect(self._handle_worker_log_message)
        self.download_worker.start()

    def _update_download_progress(self):
        if self.current_local_download_path and os.path.exists(self.current_local_download_path) and self.total_download_size > 0:
            current_size = os.path.getsize(self.current_local_download_path)
            progress_percentage = int((current_size / self.total_download_size) * 100)
            self.download_progress_bar.setValue(progress_percentage)
            self.download_progress_bar.setFormat(f"Downloading: %p% - {current_size / (1024*1024):.2f}MB / {self.total_download_size / (1024*1024):.2f}MB")
        elif not os.path.exists(self.current_local_download_path):
            self.download_progress_bar.setValue(0)
            self.download_progress_bar.setFormat("Downloading: 0% - File has not started...")


    def on_apk_download_finished(self, stdout, stderr, returncode, time_taken):
        # Stop progress timer
        self.download_progress_timer.stop()
        self.download_worker = None # Remove reference after completion

        self.display_log("--- APK Download Output ---", "#f7f5de")
        if stdout:
            self.display_log(stdout, "black")
        if stderr:
            self.display_log(stderr, "red")

        if returncode == 0:
            self.display_log("APK file successfully downloaded!", "#c0ffee")
            self.download_progress_bar.setValue(100)
            self.download_progress_bar.setFormat("Download Complete!")

            # Check if the downloaded file is a multi-part APK bundle (APKS, XAPK, APKM)
            downloaded_file_extension = os.path.splitext(self.current_local_download_path)[1].lower()
            if downloaded_file_extension in ['.apks', '.xapk', '.apkm']:
                self._process_multi_apk_download(self.current_local_download_path)

        else:
            self.display_log(f"APK download failed with code {returncode}.", "red")
            self.display_log("Please check if the APK file exists on Android and the path is correct.", "red")
            if "no such file or directory" in stderr or "does not exist" in stderr:
                self.display_log("APK file not found on Android at the specified path.", "red")
            elif "Permission denied" in stderr:
                self.display_log("Permission denied when accessing APK on Android.", "red")

        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)
        self.total_download_size = 0
        self.current_local_download_path = None
        self._re_enable_all_buttons_and_inputs_after_operation()

    def on_worker_error(self, message):
        self.display_log(f"CRITICAL ERROR: {message}", "darkred")
        # Removing QMessageBox.critical to prevent potential GUI blocking/crashing
        self._re_enable_all_buttons_and_inputs_after_operation()
        self.connection_indicator.set_status("disconnected")
        self.download_progress_bar.setVisible(False)
        self.download_progress_bar.setValue(0)
        self.total_download_size = 0
        self.current_local_download_path = None
        self.download_progress_timer.stop()
        # Set semua worker references ke None pada error kritis untuk membantu garbage collection
        self.tcpip_worker = None
        self.connect_ip_worker = None
        self.devices_worker = None
        self.disconnect_worker = None
        self.transfer_worker = None
        self.execute_worker = None
        self.apk_list_worker = None
        self.get_size_worker = None
        self.download_worker = None

if __name__ == '__main__':
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())

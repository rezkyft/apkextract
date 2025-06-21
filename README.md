Android APK Extractor via ADB
This repository contains a Python GUI application and a companion shell script to facilitate the extraction of APK files from Android devices using ADB (Android Debug Bridge).

Files
apk-extractor.py:
A Python script that provides a graphical user interface (GUI) for interacting with an Android device via ADB. It allows users to:

Connect to an Android device via USB or Wi-Fi (TCP/IP).
List installed APKs by package name.
Push and execute the extract-apk.sh script on the device.
Run the extract-apk.sh script if it's already present on the device.
Download extracted APKs from the Android device to the local machine.
Handles detection and extraction of base.apk from multi-part APKs (APKS, XAPK, APKM) during download.
Features a connection indicator, progress bar for downloads, and verbose logging.
Requires PyQt6 for the GUI.
extract-apk.sh:
A shell script designed to be run on an Android device. Its purpose is to:

Extract APKs from an Android device based on a provided package name.
Handle split APKs by iterating through all found paths for a given package.
Create an output directory /sdcard/ExtractedAPKs on the Android device to store extracted APKs.
Copy the APK file(s) to the designated output directory.
Echo "APK Extracted: [path]" for the main APK, which is parsed by the Python application.
How it Works
The apk-extractor.py application serves as a front-end to manage ADB commands. It utilizes the extract-apk.sh script to perform the actual APK extraction on the Android device.

Connection: The Python app establishes an ADB connection (USB or Wi-Fi).
Script Transfer/Execution:
If using "Push Script & Run", apk-extractor.py pushes extract-apk.sh to a temporary location on the Android device (e.g., /data/local/tmp/), sets execute permissions, and then runs it with the specified package name as an argument.
If using "Run Device Script", it directly executes extract-apk.sh (assumed to be already on the device at a specified path) with the package name.
APK Extraction: The extract-apk.sh script finds all APK paths for the given package, copies them to /sdcard/ExtractedAPKs, and prints the path of the base.apk (if found) to standard output.
Download: The Python app then pulls the extracted APK (identified from the script's output) from the Android device to the local computer. It also handles multi-part APKs (APKS, XAPK, APKM) by attempting to extract the base.apk from them.
Requirements
Python 3
PyQt6: Install with pip install PyQt6
Android SDK Platform-Tools (with ADB): Ensure ADB is installed and configured in your system's PATH.
An Android device with USB Debugging enabled.
Usage
Clone this repository.
Install dependencies: pip install PyQt6
Run the Python application: python apk-extractor.py
Follow the instructions in the GUI to connect your device, fetch APKs, and extract/download them.

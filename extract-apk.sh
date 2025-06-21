#!/system/bin/sh
# This script extracts APKs from an Android device based on package name.
# It handles split APKs by iterating through all found paths.

PACKAGE_NAME="$1" # The package name is passed as the first argument to the script
OUTPUT_DIR="/sdcard/ExtractedAPKs" # Define the output directory on the Android device

echo "INFO: Ensuring output directory exists: $OUTPUT_DIR"
# Create the output directory if it doesn't exist. Exit if creation fails.
mkdir -p "$OUTPUT_DIR" || { echo "ERROR: Failed to create output directory."; exit 1; }

echo "INFO: Attempting to find APK path for package: $PACKAGE_NAME"
# Use 'pm path' to get all APK paths for the package.
# 'sed 's/package://g'' removes the "package:" prefix from each line.
# This will output each APK path on a new line.
APK_PATHS=$(pm path "$PACKAGE_NAME" | sed 's/package://g')

# Check if any APK paths were found
if [ -z "$APK_PATHS" ]; then
    echo "ERROR: No APK paths found for package: $PACKAGE_NAME"
    exit 1
fi

echo "INFO: Found APK paths:"
echo "$APK_PATHS" # Echo all found APK paths for debugging/logging

SUCCESS_FLAG=0 # Flag to track if any copy operation fails

# Loop through each APK path found (each line in APK_PATHS)
# IFS= prevents word splitting, read -r prevents backslash interpretation
echo "$APK_PATHS" | while IFS= read -r apk_file; do
    if [ -n "$apk_file" ]; then # Ensure the line is not empty
        # Extract just the filename from the full path
        APK_FILENAME=$(basename "$apk_file")
        # Define the full destination path on the Android device
        DEST_PATH="$OUTPUT_DIR/$APK_FILENAME"

        echo "INFO: Copying '$apk_file' to '$DEST_PATH'"
        # Attempt to copy the APK file
        cp "$apk_file" "$DEST_PATH"

        if [ $? -ne 0 ]; then # Check the exit status of the cp command (0 for success, non-zero for failure)
            echo "ERROR: Failed to copy '$apk_file'. Check permissions or if the source APK exists."
            SUCCESS_FLAG=1 # Set the flag to indicate a failure
        else
            echo "INFO: Successfully copied '$APK_FILENAME'"
            # If this is the base.apk, echo a specific line that the Python app looks for
            if echo "$apk_file" | grep -q "base.apk"; then
                echo "APK Extracted: $DEST_PATH" # This line is parsed by the Python app to identify the main APK
            fi
        fi
    fi
done

# Check the SUCCESS_FLAG and exit with an appropriate code
if [ $SUCCESS_FLAG -ne 0 ]; then
    exit 1 # Exit with error code 1 if any copy operation failed
fi

exit 0 # Exit with code 0 if all operations were successful

#!/bin/bash

API_KEY=""
API_BASE_URL="https://kiosk-server-bot-proxy.fcc.lol"
CONFIG_FILE="/var/lib/homebridge/config.json"

# Fetch data from the API
fetch_data() {
  curl -s "$API_BASE_URL/urls?fccApiKey=$API_KEY"
}

# Function to extract values from JSON
extract_value() {
  local json="$1"
  local key="$2"
  echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | sed "s/\"$key\":\"//" | sed "s/\"$//"
}

# Function to extract values from JSON arrays
extract_array() {
  local json="$1"
  local items=$(echo "$json" | grep -o "\[.*\]" | sed "s/^\[//" | sed "s/\]$//")
  echo "$items" | sed "s/},{/}\n{/g"
}

# Main function
update_config() {
  # Check if config file exists
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file $CONFIG_FILE does not exist."
    exit 1
  fi

  # Check for permissions to read/write the config file
  if [ ! -r "$CONFIG_FILE" ] || [ ! -w "$CONFIG_FILE" ]; then
    echo "Error: Cannot read or write to $CONFIG_FILE. Try running the script with sudo."
    exit 1
  fi

  # Fetch the data from the API
  data=$(fetch_data)
  if [ -z "$data" ]; then
    echo "Error fetching data from API"
    exit 1
  fi

  # Create a temporary directory
  TEMP_DIR=$(mktemp -d)
  TEMP_FILE="$TEMP_DIR/temp_config.json"
  SWITCHES_FILE="$TEMP_DIR/switches.json"

  # Initialize switches array
  echo "[" > "$SWITCHES_FILE"
  
  # Process the items in the array
  items=$(extract_array "$data")
  first_item=true
  
  while IFS= read -r item; do
    if [ -n "$item" ]; then
      id=$(extract_value "$item" "id")
      title=$(extract_value "$item" "title")
      
      # Use Python to properly clean the title from emoji
      clean_title=$(python3 -c "
import re, sys, unicodedata

title = '$title'
# Remove emoji and other non-alphanumeric characters at the beginning
# This will match any character that is not a letter, number, space, or common punctuation
clean = re.sub(r'^[^\w\s.,;:!?\"\'()\\[\\]{}]+\s*', '', title)
print(clean)
")
      
      display_name="Kiosk to $clean_title"
      
      # Create switch JSON
      switch="{
        \"id\": \"$id\",
        \"name\": \"$display_name\",
        \"on_url\": \"$API_BASE_URL/change-url\",
        \"on_method\": \"POST\",
        \"on_body\": \"{ \\\"id\\\": \\\"$id\\\", \\\"fccApiKey\\\": \\\"$API_KEY\\\" }\",
        \"on_headers\": \"{ \\\"Content-Type\\\": \\\"application/json\\\" }\"
      }"
      
      # Add comma before item if not the first item
      if [ "$first_item" = true ]; then
        first_item=false
      else
        echo "," >> "$SWITCHES_FILE"
      fi
      
      # Add switch to file
      echo "$switch" >> "$SWITCHES_FILE"
    fi
  done <<< "$items"
  
  # Close switches array
  echo "]" >> "$SWITCHES_FILE"
  
  # Get the switches JSON
  switches=$(cat "$SWITCHES_FILE")
  
  # Create new config with updated switches
  python3 -c "
import json, sys

# Read the config file
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)

# Read the switches
with open('$SWITCHES_FILE', 'r') as f:
    switches = json.load(f)

# Find the HttpWebHooks platform or add it
webhook_platform = None
for i, platform in enumerate(config.get('platforms', [])):
    if platform.get('platform') == 'HttpWebHooks':
        webhook_platform = platform
        break

if webhook_platform:
    webhook_platform['switches'] = switches
else:
    config['platforms'].append({
        'webhook_port': '51828',
        'switches': switches,
        'platform': 'HttpWebHooks'
    })

# Write the updated config
with open('$TEMP_FILE', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null

  if [ $? -eq 0 ] && [ -f "$TEMP_FILE" ]; then
    # Move the temp file to the config location
    mv "$TEMP_FILE" "$CONFIG_FILE"
    echo "Config file updated successfully at $CONFIG_FILE!"
  else
    echo "Error updating config file"
    exit 1
  fi
  
  # Clean up temp directory
  rm -rf "$TEMP_DIR"
}

# Run the script
update_config

#!/bin/bash

# interact/account-helpers/bitlaunch.sh

AXIOM_PATH="$HOME/.axiom"
source "$AXIOM_PATH/interact/includes/vars.sh"
source "$AXIOM_PATH/providers/bitlaunch-functions.sh"

echo -e "${BGreen}Setting up BitLaunch Account...${Color_Off}"

# 1. Check and install blcli
_bl_ensure_cli_installed

# 2. Check blcli version (optional but good practice)
INSTALLED_VERSION=$(blcli version --short | sed 's/v//')
if [[ "$(printf '%s\n' "$INSTALLED_VERSION" "$BlcliVersion" | sort -V | head -n 1)" != "$BlcliVersion" ]]; then
    echo -e "${BYellow}Warning: Your blcli version ($INSTALLED_VERSION) is older than the recommended version ($BlcliVersion). You may encounter issues.${Color_Off}"
fi

# 3. Interactively get and validate the API Token
TOKEN=""
BL_OPTIONS_JSON=""
while true; do
    echo -e -n "${BGreen}Please enter your BitLaunch API Token (get it from https://app.bitlaunch.io/user/api):\n>> ${Color_Off}"
    read TOKEN
    if [ -z "$TOKEN" ]; then
        echo -e "${BRed}Error: Token cannot be empty. Please try again.${Color_Off}"
        continue
    fi

    echo "Verifying token..."
    VERIFY_OUTPUT=$(blcli account show --token "$TOKEN" 2>&1)
    
    if echo "$VERIFY_OUTPUT" | grep -q "error 401"; then
        echo -e "${BRed}Error: The provided API Token is invalid (401 Unauthorized). Please check your token and try again.${Color_Off}"
    elif echo "$VERIFY_OUTPUT" | grep -q "Error"; then
        echo -e "${BRed}An unknown error occurred while verifying the token:${Color_Off}"
        echo "$VERIFY_OUTPUT"
    else
        echo -e "${BGreen}Token verified successfully.${Color_Off}"
        echo "Fetching available instance options..."
        if [ -f "$AXIOM_PATH/create-options.json" ]; then
            echo "Using local create-options.json for setup..."
            BL_OPTIONS_JSON=$(cat "$AXIOM_PATH/create-options.json")
        else
            BL_OPTIONS_JSON=$(blcli create-options bitlaunch --token "$TOKEN")
        fi
        
        if [ -z "$BL_OPTIONS_JSON" ] || ! echo "$BL_OPTIONS_JSON" | jq . > /dev/null 2>&1; then
             echo -e "${BRed}Failed to fetch or parse creation options from BitLaunch. Please try again.${Color_Off}"
        else
            break 
        fi
    fi
done


# 4. Guide user to select default parameters
DEFAULT_IMAGE_ID=""
DEFAULT_IMAGE_OBJ=""
DEFAULT_REGION_ID=""
DEFAULT_REGION_OBJ=""
DEFAULT_SUBREGION_ID=""
DEFAULT_SUBREGION_OBJ=""
DEFAULT_SIZE_ID=""

# Step 4a: Select Image (Two-step process)
# First, select the OS Name
while true; do
    echo -e "\n${BGreen}Please select a default Operating System:${Color_Off}"
    
    mapfile -t os_names < <(echo "$BL_OPTIONS_JSON" | jq -r '.image[] | .name')

    PS3="Your choice for OS: "
    select choice in "${os_names[@]}"; do
        if [[ -n "$choice" ]]; then
            SELECTED_OS_OBJ=$(echo "$BL_OPTIONS_JSON" | jq --arg name "$choice" '.image[] | select(.name == $name)')
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    if [ -n "$SELECTED_OS_OBJ" ]; then
        echo "Selected OS: $choice"
        break
    fi
    echo -e "${BRed}Invalid input. Please choose a number from the list.${Color_Off}"
done

# Second, select the OS Version from the chosen OS
while true; do
    echo -e "\n${BGreen}Please select a version for '$choice':${Color_Off}"
    
    mapfile -t version_descs < <(echo "$SELECTED_OS_OBJ" | jq -r '.versions[] | .description')
    mapfile -t version_ids < <(echo "$SELECTED_OS_OBJ" | jq -r '.versions[] | .id')

    PS3="Your choice for Version: "
    select version_choice in "${version_descs[@]}"; do
        if [[ -n "$version_choice" ]]; then
            DEFAULT_IMAGE_ID=${version_ids[$REPLY - 1]}
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    if [ -n "$DEFAULT_IMAGE_ID" ]; then
        DEFAULT_IMAGE_OBJ=$(echo "$SELECTED_OS_OBJ" | jq --arg id "$DEFAULT_IMAGE_ID" '.versions[] | select(.id == $id)')
        if [ -n "$DEFAULT_IMAGE_OBJ" ]; then
            echo "Selected Version: $version_choice"
            break
        fi
    fi
    echo -e "${BRed}Invalid input. Please choose a number from the list.${Color_Off}"
done

# Step 4b: Select Region
while true; do
    echo -e "\n${BGreen}Please select a default Region:${Color_Off}"
    
    UNAVAILABLE_REGIONS=$(echo "$DEFAULT_IMAGE_OBJ" | jq -r 'if .unavailableRegions then .unavailableRegions[] else empty end')
    
    mapfile -t region_names < <(echo "$BL_OPTIONS_JSON" | jq -r --arg unavailable "$UNAVAILABLE_REGIONS" \
        '.region[] | select(.id as $region_id | $unavailable | split("\n") | index($region_id | tostring) | not) | .name')
    mapfile -t region_ids < <(echo "$BL_OPTIONS_JSON" | jq -r --arg unavailable "$UNAVAILABLE_REGIONS" \
        '.region[] | select(.id as $region_id | $unavailable | split("\n") | index($region_id | tostring) | not) | .id')

    PS3="Your choice: "
    select choice in "${region_names[@]}"; do
        if [[ -n "$choice" ]]; then
            DEFAULT_REGION_ID=${region_ids[$REPLY - 1]}
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    if [ -n "$DEFAULT_REGION_ID" ]; then
        DEFAULT_REGION_OBJ=$(echo "$BL_OPTIONS_JSON" | jq --arg id "$DEFAULT_REGION_ID" '.region[] | select(.id | tostring == $id)')
        if [ -n "$DEFAULT_REGION_OBJ" ]; then
            echo "Selected Region: $choice"
            break
        fi
    fi
    echo -e "${BRed}Invalid input. Please choose a number from the list.${Color_Off}"
done

# Get total number of sizes once
TOTAL_SIZE_COUNT=$(echo "$BL_OPTIONS_JSON" | jq -r '.size | length')

# Step 4c: Select Subregion
while true; do
    echo -e "\n${BGreen}Please select a default Subregion:${Color_Off}"
    RECOMMENDED_SUBREGION_ID=$(echo "$DEFAULT_REGION_OBJ" | jq -r '.subregion.id')
    
    subregion_names=()
    subregion_ids=()

    # Manually iterate through subregions to build the choice list
    while read -r subregion_obj; do
        subregion_id=$(echo "$subregion_obj" | jq -r '.id')
        unavailable_size_count=$(echo "$subregion_obj" | jq -r '.unavailableSizes | length')

        # Only add subregion if it has at least one available size
        if [ "$unavailable_size_count" -lt "$TOTAL_SIZE_COUNT" ]; then
            display_name="$subregion_id"
            if [ "$subregion_id" == "$RECOMMENDED_SUBREGION_ID" ]; then
                display_name="$subregion_id (Recommended)"
            fi
            subregion_names+=("$display_name")
            subregion_ids+=("$subregion_id")
        fi
    done < <(echo "$DEFAULT_REGION_OBJ" | jq -c '.subregions[]')
    
    PS3="Your choice: "
    select choice in "${subregion_names[@]}"; do
        if [[ -n "$choice" ]]; then
            # Get the original ID without the "(Recommended)" text
            chosen_id_from_menu=$(echo "$choice" | awk '{print $1}')
            DEFAULT_SUBREGION_ID=$chosen_id_from_menu
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    if [ -n "$DEFAULT_SUBREGION_ID" ]; then
        DEFAULT_SUBREGION_OBJ=$(echo "$DEFAULT_REGION_OBJ" | jq --arg id "$DEFAULT_SUBREGION_ID" '.subregions[] | select(.id == $id)')
        if [ -n "$DEFAULT_SUBREGION_OBJ" ]; then
            echo "Selected Subregion: $DEFAULT_SUBREGION_ID"
            break
        fi
    fi
    echo -e "${BRed}Invalid input. Please choose a number from the list.${Color_Off}"
done

# Step 4d: Select Size
while true; do
    echo -e "\n${BGreen}Please select a default instance Size:${Color_Off}"

    UNAVAILABLE_SIZES=$(echo "$DEFAULT_SUBREGION_OBJ" | jq -r '.unavailableSizes[]')
    
    mapfile -t size_names < <(echo "$BL_OPTIONS_JSON" | jq -r --arg unavailable "$UNAVAILABLE_SIZES" \
        '.size[] | select(.id as $size_id | $unavailable | split("\n") | index($size_id) | not) | "\(.slug) (\(.cpuCount) vCPU, \(.memoryMB)MB RAM, \(.diskGB)GB Disk)"')
    mapfile -t size_ids < <(echo "$BL_OPTIONS_JSON" | jq -r --arg unavailable "$UNAVAILABLE_SIZES" \
        '.size[] | select(.id as $size_id | $unavailable | split("\n") | index($size_id) | not) | .id')
    
    if [ ${#size_names[@]} -eq 0 ]; then
        # This case should technically not be reached due to subregion filtering, but as a safeguard:
        echo -e "\n${BRed}Error: No compatible instance sizes found for the selected subregion '$DEFAULT_SUBREGION_ID'.${Color_Off}"
        exit 1
    fi

    PS3="Your choice: "
    select choice in "${size_names[@]}"; do
        if [[ -n "$choice" ]]; then
            DEFAULT_SIZE_ID=${size_ids[$REPLY - 1]}
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    if [ -n "$DEFAULT_SIZE_ID" ]; then
        echo "Selected Size: $choice"
        break
    fi
    echo -e "${BRed}Invalid input. Please choose a number from the list.${Color_Off}"
done


# 5. Save Configuration
echo -e -n "\n${BWhite}Please enter a name for this account profile (e.g. 'bl-main', lowercase and dashes only):\n>> ${Color_Off}"
read title
if [[ -z "$title" ]]; then
    title="bitlaunch"
    echo -e "${BGreen}No name entered, using default: 'bitlaunch'${Color_Off}"
fi

mkdir -p "$AXIOM_PATH/accounts/"

DATA=$(jq -n \
    --arg provider "bitlaunch" \
    --arg token "$TOKEN" \
    --arg region "$DEFAULT_SUBREGION_ID" \
    --arg size "$DEFAULT_SIZE_ID" \
    --arg image "$DEFAULT_IMAGE_ID" \
    '{provider: $provider, token: $token, default_region: $region, default_size: $size, default_image: $image}')

# Add sshkey to the configuration and ensure the key exists
DATA=$(echo "$DATA" | jq '. + {sshkey: "axiom_rsa"}')

if [ ! -f "$HOME/.ssh/axiom_rsa" ]; then
    echo "SSH key 'axiom_rsa' not found, creating a new one..."
    ssh-keygen -b 2048 -t rsa -f "$HOME/.ssh/axiom_rsa" -q -N ""
    echo "SSH key 'axiom_rsa' created."
fi

echo "$DATA" | jq . > "$AXIOM_PATH/accounts/$title.json"
echo -e "${BGreen}Successfully saved account profile '$title' to '$AXIOM_PATH/accounts/$title.json'${Color_Off}"

"$AXIOM_PATH/interact/axiom-account" "$title"
echo -e "${BGreen}BitLaunch account '$title' is now the active account.${Color_Off}"

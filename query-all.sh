#!/bin/bash

# Input and output files
input_csv="principals.csv"
output_csv="principals_with_balance.csv"
failed_csv="failed_principals.csv"
retry_csv="retry_failed_principals.csv"
success_csv="retried_principals_with_balance.csv"
errors_csv="error_principals.csv"

# Add headers to the output CSVs
echo "Principal,Subaccount,Balance" > "$output_csv"
echo "Principal,Subaccount" > "$failed_csv"

# --- First Pass: Query principals.csv ---

echo "Starting first pass: Querying balances from principals.csv..."

tail -n +2 "$input_csv" | while IFS= read -r account; do
    # Trim spaces and sanitize input
    account=$(echo "$account" | tr -d '[:space:]' | tr -d '"')

    if [[ "$account" == *.* ]]; then
        # Handle non-default accounts with subaccount
        principal_subaccount=$(echo "$account" | cut -d'.' -f1)
        subaccount_hex=$(echo "$account" | cut -d'.' -f2)

        owner=$(echo "$principal_subaccount" | cut -d'-' -f1-5)  # Extract full principal

        # Format subaccount as blob and ensure it's exactly 32 bytes
        subaccount_blob=$(echo "$subaccount_hex" | sed 's/../\\&/g')  # Convert hex to blob format
        subaccount_length=$(echo -n "$subaccount_blob" | tr -d '\\' | wc -c)

        if [[ "$subaccount_length" -lt 64 ]]; then
            # Pad with leading zeros if less than 32 bytes
            padding=$(printf '\\00%.0s' $(seq 1 $((64 - subaccount_length))))
            subaccount_blob="$padding$subaccount_blob"
        elif [[ "$subaccount_length" -gt 64 ]]; then
            # Truncate if longer than 32 bytes
            subaccount_blob=$(echo "$subaccount_blob" | cut -c-$((64 + 31)))  # Keep first 64 chars
        fi

        echo "Querying balance for owner: $owner with subaccount: opt blob \"$subaccount_blob\"..."
        candid_args="(
            record { 
                owner = principal \"$owner\"; 
                subaccount = opt blob \"$subaccount_blob\" 
            }
        )"
    else
        # Handle default accounts (no subaccount)
        owner="$account"
        echo "Querying balance for owner: $owner (default account)..."
        candid_args="(
            record { 
                owner = principal \"$owner\"; 
                subaccount = null 
            }
        )"
        subaccount_hex=""  # No subaccount
    fi

    # Query the balance
    balance=$(dfx canister --network ic call --query k45jy-aiaaa-aaaaq-aadcq-cai icrc1_balance_of "$candid_args" 2>&1)

    # Check if the call succeeded
    if [[ $? -ne 0 ]]; then
        echo "Error querying balance for $account"
        echo "$owner,$subaccount_hex" >> "$failed_csv"
        continue
    fi

    # Extract the balance value (nat) and remove ": nat"
    balance_value=$(echo "$balance" | awk -F'[()]' '{print $2}' | sed 's/ : nat//g' | tr -d '_')

    # Ensure balance_value is numeric before comparing
    if [[ "$balance_value" =~ ^[0-9]+$ && "$balance_value" -gt 0 ]]; then
        echo "$owner,$subaccount_hex,$balance_value" >> "$output_csv"
        echo "Account: $owner.$subaccount_hex has balance: $balance_value"
    else
        echo "Account: $owner.$subaccount_hex has no balance."
    fi
done

echo "First pass complete. Moving to retrying failed principals..."

# --- Second Pass: Retry failed_principals.csv ---
echo "Principal,Subaccount,Balance" > "$success_csv"
echo "Principal,Subaccount" > "$retry_csv"
echo "Principal,Subaccount" > "$errors_csv"

tail -n +2 "$failed_csv" | while IFS=',' read -r principal subaccount; do
    # Remove spaces and sanitize input
    principal=$(echo "$principal" | tr -d '[:space:]')
    subaccount=$(echo "$subaccount" | tr -d '[:space:]')

    if [[ -z "$subaccount" ]]; then
        echo "Error: Missing subaccount for $principal. Skipping..."
        echo "$principal," >> "$retry_csv"
        echo "$principal," >> "$errors_csv"
        continue
    fi

    # Ensure subaccount is properly formatted (32 bytes or 64 characters)
    subaccount_length=${#subaccount}
    if [[ "$subaccount_length" -lt 64 ]]; then
        # Pad with leading zeros
        padding=$(printf "%0$((64 - subaccount_length))s" "" | tr ' ' '0')
        subaccount="${padding}${subaccount}"
    elif [[ "$subaccount_length" -gt 64 ]]; then
        # Truncate if longer than 64 characters
        subaccount=${subaccount:0:64}
    fi

    # Format subaccount as blob using \NN (Candid-compatible format)
    subaccount_blob=$(echo "$subaccount" | sed 's/../\\&/g')
    candid_args="(
        record { 
            owner = principal \"$principal\"; 
            subaccount = opt blob \"$subaccount_blob\" 
        }
    )"
    echo "Retrying balance for owner: $principal with subaccount: opt blob \"$subaccount_blob\"..."

    # Query the balance
    balance=$(dfx canister --network ic call k45jy-aiaaa-aaaaq-aadcq-cai icrc1_balance_of "$candid_args" 2>&1)

    # Check if the call succeeded
    if [[ $? -ne 0 ]]; then
        echo "Retry failed for $principal with subaccount $subaccount."
        echo "$principal,$subaccount" >> "$retry_csv"
        echo "$principal,$subaccount" >> "$errors_csv"
        continue
    fi

    # Extract the balance value (nat) and remove ": nat"
    balance_value=$(echo "$balance" | awk -F'[()]' '{print $2}' | sed 's/ : nat//g' | tr -d '_')

    # Ensure balance_value is numeric before recording
    if [[ "$balance_value" =~ ^[0-9]+$ && "$balance_value" -gt 0 ]]; then
        echo "$principal,$subaccount,$balance_value" >> "$output_csv"
        echo "Retried account: $principal with subaccount $subaccount has balance: $balance_value"
    else
        echo "Retried account: $principal with subaccount $subaccount has no balance."
    fi
done

echo "All entries have been processed. Exiting..."
exit 0


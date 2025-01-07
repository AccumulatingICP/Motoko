#!/bin/bash

# Input and output files
failed_csv="failed_principals.csv"
retry_csv="retry_failed_principals.csv"
success_csv="retried_principals_with_balance.csv"
errors_csv="error_principals.csv"

# Add headers to the output CSVs
echo "Principal,Subaccount,Balance" > "$success_csv"
echo "Principal,Subaccount,Error" > "$retry_csv"
echo "Principal,Subaccount,Error" > "$errors_csv"

# Process each line in the failed CSV
tail -n +2 "$failed_csv" | while IFS=',' read -r principal subaccount error; do
    # Remove spaces and sanitize input
    principal=$(echo "$principal" | tr -d '[:space:]')
    subaccount=$(echo "$subaccount" | tr -d '[:space:]')

    if [[ -z "$subaccount" ]]; then
        echo "Error: Missing subaccount for $principal. Skipping..."
        echo "$principal,,Missing subaccount" >> "$retry_csv"
        echo "$principal,,Missing subaccount" >> "$errors_csv"
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
        echo "Retry failed for $principal: $balance"
        echo "$principal,$subaccount,\"$balance\"" >> "$retry_csv"
        echo "$principal,$subaccount,\"$balance\"" >> "$errors_csv"
        continue
    fi

    # Extract the balance value (nat) and remove ": nat"
    balance_value=$(echo "$balance" | awk -F'[()]' '{print $2}' | sed 's/ : nat//g' | tr -d '_')

    # Ensure balance_value is numeric before recording
    if [[ "$balance_value" =~ ^[0-9]+$ && "$balance_value" -gt 0 ]]; then
        echo "$principal,$subaccount,$balance_value" >> "$success_csv"
        echo "Retried account: $principal with subaccount $subaccount has balance: $balance_value"
    else
        echo "Retried account: $principal with subaccount $subaccount has no balance."
    fi
done

# Gracefully exit the script after processing all lines
echo "All entries have been processed. Exiting..."
exit 0


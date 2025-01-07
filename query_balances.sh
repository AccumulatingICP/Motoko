#!/bin/bash

# Input and output files
input_csv="principals.csv"
output_csv="principals_with_balance.csv"
failed_csv="failed_principals.csv"

# Add headers to the output CSVs
echo "Principal,Subaccount,Balance" > "$output_csv"
echo "Principal,Subaccount" > "$failed_csv"

# Process each line in the CSV
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

    # Query the balance with `--query` for faster execution
    balance=$(dfx canister --network ic call --query k45jy-aiaaa-aaaaq-aadcq-cai icrc1_balance_of "$candid_args" 2>&1)

    # Check if the call succeeded
    if [[ $? -ne 0 ]]; then
        echo "Error querying balance for $account: $balance"
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


#!/bin/bash

# ---------------------------------------------------------
# Input and output files
# ---------------------------------------------------------
input_csv="principals.csv"
output_pass1="successful_queries_pass1.csv"
output_pass2="successful_queries_pass2.csv"
failed_first_pass_csv="failed_first_pass.csv"
failed_final_csv="failed_queries_final.csv"

# Add headers to output files
echo "Principal,Subaccount,Balance" > "$output_pass1"
echo "Principal,Subaccount,Balance" > "$output_pass2"
echo "Principal,Subaccount" > "$failed_first_pass_csv"
echo "Principal,Subaccount" > "$failed_final_csv"

# ---------------------------------------------------------
# Function to format subaccount as a blob
# ---------------------------------------------------------
format_subaccount_blob() {
    local subaccount="$1"
    echo "$subaccount" | sed 's/../\\&/g'
}

# ---------------------------------------------------------
# Function to query balance
# ---------------------------------------------------------
query_balance() {
    local principal="$1"
    local subaccount="$2"

    # Format subaccount as blob if provided
    local candid_args
    if [[ -n "$subaccount" ]]; then
        local subaccount_blob
        subaccount_blob="$(format_subaccount_blob "$subaccount")"
        candid_args="(
            record {
                owner = principal \"$principal\";
                subaccount = opt blob \"$subaccount_blob\"
            }
        )"
    else
        candid_args="(
            record {
                owner = principal \"$principal\";
                subaccount = null
            }
        )"
    fi

    # Query the balance
    local balance
    balance="$(dfx canister --network ic call k45jy-aiaaa-aaaaq-aadcq-cai icrc1_balance_of "$candid_args" 2>&1)"
    local exit_code=$?

    # If call fails => return error
    if (( exit_code != 0 )); then
        # Return 1 => indicates an error
        return 1
    fi

    # Extract the balance value (nat) and remove ": nat"
    local balance_value
    balance_value="$(echo "$balance" | awk -F'[()]' '{print $2}' | sed 's/ : nat//g' | tr -d '_')"

    # If numeric AND > 0 => success, else partial info
    if [[ "$balance_value" =~ ^[0-9]+$ && "$balance_value" -gt 0 ]]; then
        # Return 0 => success, and echo only the balance
        echo "$balance_value"
        return 0
    else
        # Return partial
        echo ""
        return 2
    fi
}

# ---------------------------------------------------------
# Pass 1: Query principals.csv
# ---------------------------------------------------------
tail -n +2 "$input_csv" | while IFS=',' read -r orig_principal orig_subaccount; do
    # Remove spaces
    orig_principal="$(echo "$orig_principal" | tr -d '[:space:]')"
    orig_subaccount="$(echo "$orig_subaccount" | tr -d '[:space:]')"

    # Query
    balance_val="$(query_balance "$orig_principal" "$orig_subaccount")"
    status=$?

    if [[ $status -eq 0 ]]; then
        # success => log original principal,subaccount,balance
        echo "$orig_principal,$orig_subaccount,$balance_val" >> "$output_pass1"
    else
        # fail => only log original principal,subaccount
        echo "$orig_principal,$orig_subaccount" >> "$failed_first_pass_csv"
    fi
done

# ---------------------------------------------------------
# Pass 2: Retry Failed Queries
# ---------------------------------------------------------
tail -n +2 "$failed_first_pass_csv" | while IFS=',' read -r orig_principal orig_subaccount; do
    orig_principal="$(echo "$orig_principal" | tr -d '[:space:]')"
    orig_subaccount="$(echo "$orig_subaccount" | tr -d '[:space:]')"

    # If the principal has something like principal-subprefix.subhex
    # we do the fix
    local fix_balance
    if [[ "$orig_principal" == *-*.* ]]; then
        # parse out 'main_principal' and 'subaccount_hex'
        main_principal="$(echo "$orig_principal" | cut -d'-' -f1-5)"
        subaccount_hex="$(echo "$orig_principal" | cut -d'.' -f2)"
        fix_balance="$(query_balance "$main_principal" "$subaccount_hex")"
    else
        # normal approach
        fix_balance="$(query_balance "$orig_principal" "$orig_subaccount")"
    fi

    status=$?
    if [[ $status -eq 0 ]]; then
        # success => log original line + numeric
        echo "$orig_principal,$orig_subaccount,$fix_balance" >> "$output_pass2"
    else
        # fail => final fail
        echo "$orig_principal,$orig_subaccount" >> "$failed_final_csv"
    fi
done

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
echo "All queries have been processed."
echo "Summary:"
echo "- Successful queries (Pass 1): $output_pass1"
echo "- Successful queries (Pass 2): $output_pass2"
echo "- Failed queries (First Pass): $failed_first_pass_csv"
echo "- Failed queries (Final): $failed_final_csv"


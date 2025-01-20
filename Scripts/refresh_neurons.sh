#!/bin/bash

# Input and output files
input_csv="neurons.csv"
output_csv="refreshed_neurons.csv"
error_csv="failed_neurons.csv"

# Add headers to the output CSVs
echo "Subaccount" > "$output_csv"
echo "Subaccount,Error" > "$error_csv"

# Function to construct the `vec` argument for subaccount
construct_vec() {
    local subaccount="$1"
    local vec=""
    for (( i=0; i<${#subaccount}; i+=2 )); do
        # Convert each two-character hex pair to decimal
        byte="0x${subaccount:$i:2}"
        vec+="$((byte)); "
    done
    # Trim trailing space and semicolon
    echo "${vec%; }"
}

# Process each subaccount from the input CSV
tail -n +2 "$input_csv" | while IFS=',' read -r subaccount; do
    # Remove spaces and sanitize input
    subaccount=$(echo "$subaccount" | tr -d '[:space:]')

    # Construct the vec argument
    subaccount_vec=$(construct_vec "$subaccount")

    # Build the Candid argument
    candid_args="(
      record {
        subaccount = vec { $subaccount_vec };
        command = opt variant {
          ClaimOrRefresh = record {
            by = opt variant {
              NeuronId = record {}
            }
          }
        }
      }
    )"

    # Call the canister to refresh the neuron
    result=$(dfx canister --network ic call k34pm-nqaaa-aaaaq-aadca-cai manage_neuron "$candid_args" 2>&1)
    exit_code=$?

    if (( exit_code == 0 )); then
        echo "$subaccount" >> "$output_csv"
    else
        echo "$subaccount,\"$result\"" >> "$error_csv"
    fi
done

echo "Processing complete."
echo "Refreshed neurons logged in $output_csv"
echo "Failed neurons logged in $error_csv"


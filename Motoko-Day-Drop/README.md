# Instructions for reproducible build
_(only works on Ubuntu/Linux right now)_

1. Install git
- ```sudo apt install git -y```

2. Git clone repo
- ```git clone https://github.com/Toniq-Labs/motoko-day-drop.git```

3. Install dfxvm with the correct dfx version for this canister
- ```DFX_VERSION=0.15.0-beta.3 sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"```
- you will have to hit enter a few times to accept the default installation

4. Install correct vessel version for this canister
- ```cd $HOME/../bin```
- ```wget https://github.com/dfinity/vessel/releases/download/v0.6.2/vessel-linux64```
- ```mv vessel-linux64 vessel```
- ```chmod +x vessel```

5. Navigate to the motoko-day-drop folder (github repo you previously cloned)

6. Start your local replica
- ```dfx start --clean```

7. Start another terminal and create canister
- ```dfx canister create motokoghosts```

8. Locally deploy the first time
- ```dfx deploy```

9. Locally deploy a second time to get the .wasm hash
- ```dfx deploy```

10. You can then check the hash given to you by dfx against the canister hash reported on the dashboard
- https://dashboard.internetcomputer.org/canister/oeee4-qaaaa-aaaak-qaaeq-cai

Finished!

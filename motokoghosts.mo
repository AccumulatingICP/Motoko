import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Char "mo:base/Char";
import Cycles "mo:base/ExperimentalCycles";
import HashMap "mo:base/HashMap";
import Int "mo:base/Int";
import Int64 "mo:base/Int64";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Nat8 "mo:base/Nat8";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";

import Cap "mo:cap/Cap";
import Encoding "mo:encoding/Binary";

import AID "../motoko/util/AccountIdentifier";
import ExtAllowance "../motoko/ext/Allowance";
import ExtCommon "../motoko/ext/Common";
import ExtCore "../motoko/ext/Core";
import ExtNonFungible "../motoko/ext/NonFungible";
shared (install) actor class nft_canister() = this {

  // Types
  type Time = Time.Time;
  type AccountIdentifier = ExtCore.AccountIdentifier;
  type SubAccount = ExtCore.SubAccount;
  type User = ExtCore.User;
  type Balance = ExtCore.Balance;
  type TokenIdentifier = ExtCore.TokenIdentifier;
  type TokenIndex = ExtCore.TokenIndex;
  type Extension = ExtCore.Extension;
  type CommonError = ExtCore.CommonError;
  type BalanceRequest = ExtCore.BalanceRequest;
  type BalanceResponse = ExtCore.BalanceResponse;
  type TransferRequest = ExtCore.TransferRequest;
  type TransferResponse = ExtCore.TransferResponse;
  type AllowanceRequest = ExtAllowance.AllowanceRequest;
  type ApproveRequest = ExtAllowance.ApproveRequest;
  type Metadata = ExtCommon.Metadata;
  type MintRequest = ExtNonFungible.MintRequest;
  type NotifyService = ExtCore.NotifyService;

  //Marketplace
  type Transaction = {
    token : TokenIdentifier;
    seller : Principal;
    price : Nat64;
    buyer : AccountIdentifier;
    time : Time;
  };
  type Settlement = {
    seller : Principal;
    price : Nat64;
    subaccount : SubAccount;
    buyer : AccountIdentifier;
  };
  type Listing = {
    seller : Principal;
    price : Nat64;
    locked : ?Time;
  };
  type ListRequest = {
    token : TokenIdentifier;
    from_subaccount : ?SubAccount;
    price : ?Nat64;
  };
  type AccountBalanceArgs = { account : AccountIdentifier };
  type ICPTs = { e8s : Nat64 };

  type SendArgs = {
    memo : Nat64;
    amount : ICPTs;
    fee : ICPTs;
    from_subaccount : ?SubAccount;
    to : AccountIdentifier;
    created_at_time : ?Time;
  };
  let LEDGER_CANISTER = actor "ryjl3-tyaaa-aaaaa-aaaba-cai" : actor {
    send_dfx : shared SendArgs -> async Nat64;
    account_balance_dfx : shared query AccountBalanceArgs -> async ICPTs;
  };

  //Cap
  type CapDetailValue = {
    #I64 : Int64;
    #U64 : Nat64;
    #Vec : [CapDetailValue];
    #Slice : [Nat8];
    #Text : Text;
    #True;
    #False;
    #Float : Float;
    #Principal : Principal;
  };
  type CapEvent = {
    time : Nat64;
    operation : Text;
    details : [(Text, CapDetailValue)];
    caller : Principal;
  };
  type CapIndefiniteEvent = {
    operation : Text;
    details : [(Text, CapDetailValue)];
    caller : Principal;
  };
  //EXTv2 SALE
  private stable var _disbursementsState : [(TokenIndex, AccountIdentifier, SubAccount, Nat64)] = [];
  private stable var _nextSubAccount : Nat = 0;
  private var _disbursements : List.List<(TokenIndex, AccountIdentifier, SubAccount, Nat64)> = List.fromArray(_disbursementsState);
  private var salesFees : [(AccountIdentifier, Nat64)] = [
    ("6f42eb919c18b05a79904bf7214bfce9d1cd365ea3bfcb51012098fe996fab59", 2500), //Royalty Fee
  ];

  //CAP
  private stable var capRootBucketId : ?Text = null;
  let CapService = Cap.Cap(?"lj532-6iaaa-aaaah-qcc7a-cai", capRootBucketId);
  private stable var _capEventsState : [CapIndefiniteEvent] = [];
  private var _capEvents : List.List<CapIndefiniteEvent> = List.fromArray(_capEventsState);
  private stable var _runHeartbeat : Bool = true;

  private let EXTENSIONS : [Extension] = ["@ext/common", "@ext/nonfungible"];

  //State work
  private stable var _registryState : [(TokenIndex, AccountIdentifier)] = [];
  private stable var _tokenMetadataState : [(TokenIndex, Metadata)] = [];
  private stable var _ownersState : [(AccountIdentifier, [TokenIndex])] = [];

  //For marketplace
  private stable var _tokenListingState : [(TokenIndex, Listing)] = [];
  private stable var _tokenSettlementState : [(TokenIndex, Settlement)] = [];
  private stable var _paymentsState : [(Principal, [SubAccount])] = [];
  private stable var _claimState : [(Principal, TokenIndex)] = [];

  private var _registry : HashMap.HashMap<TokenIndex, AccountIdentifier> = HashMap.fromIter(_registryState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _tokenMetadata : HashMap.HashMap<TokenIndex, Metadata> = HashMap.fromIter(_tokenMetadataState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _tokenMetadataQuickIndex : HashMap.HashMap<TokenIndex, Metadata> = HashMap.fromIter(Iter.map<(TokenIndex, Metadata), (TokenIndex, Metadata)>(_tokenMetadataState.vals(), func(a : (TokenIndex, Metadata)) : (TokenIndex, Metadata) { (a.0, #nonfungible({ metadata = null })) }), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _owners : HashMap.HashMap<AccountIdentifier, [TokenIndex]> = HashMap.fromIter(_ownersState.vals(), 0, AID.equal, AID.hash);

  //For marketplace
  private var _tokenListing : HashMap.HashMap<TokenIndex, Listing> = HashMap.fromIter(_tokenListingState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _tokenSettlement : HashMap.HashMap<TokenIndex, Settlement> = HashMap.fromIter(_tokenSettlementState.vals(), 0, ExtCore.TokenIndex.equal, ExtCore.TokenIndex.hash);
  private var _payments : HashMap.HashMap<Principal, [SubAccount]> = HashMap.fromIter(_paymentsState.vals(), 0, Principal.equal, Principal.hash);
  private var ESCROWDELAY : Time = 10 * 60 * 1_000_000_000;
  private stable var _usedPaymentAddressess : [(AccountIdentifier, Principal, SubAccount)] = [];
  private stable var _transactions : [Transaction] = [];
  private stable var _supply : Balance = 0;
  private stable var _minter : Principal = Principal.fromText("sensj-ihxp6-tyvl7-7zwvj-fr42h-7ojjp-n7kxk-z6tvo-vxykp-umhfk-wqe");
  private stable var _nextTokenId : TokenIndex = 0;

  private var _claim : HashMap.HashMap<Principal, TokenIndex> = HashMap.fromIter(_claimState.vals(), 0, Principal.equal, Principal.hash);

  stable var _claimed : Nat = 0;
  stable var _tokensForClaim : [TokenIndex] = [];
  stable var totpoffset : Int = 27261284;
  stable var totplookup : [Text] = [];
  stable var mdmap : [TokenIndex] = [];
  var _tokensForClaimList : List.List<TokenIndex> = List.fromArray(_tokensForClaim);
  //State functions
  system func preupgrade() {
    _registryState := Iter.toArray(_registry.entries());
    _tokenMetadataState := Iter.toArray(_tokenMetadata.entries());
    _ownersState := Iter.toArray(_owners.entries());
    _tokenListingState := Iter.toArray(_tokenListing.entries());
    _tokenSettlementState := Iter.toArray(_tokenSettlement.entries());
    _paymentsState := Iter.toArray(_payments.entries());
    _claimState := Iter.toArray(_claim.entries());
    _tokensForClaim := List.toArray(_tokensForClaimList);
    //EXTv2 SALE
    _disbursementsState := List.toArray(_disbursements);

    //Cap
    _capEventsState := List.toArray(_capEvents);
  };
  system func postupgrade() {
    _registryState := [];
    _tokenMetadataState := [];
    _ownersState := [];
    _tokenListingState := [];
    _tokenSettlementState := [];
    _paymentsState := [];
    _claimState := [];
    _tokensForClaim := [];
    //EXTv2 SALE
    _disbursementsState := [];

    //Cap
    _capEventsState := [];
  };
  //Claim
  func checkTOTP(code : Text) : Bool {
    var t = (Time.now() / 60000000000) - totpoffset;
    if (t < 0) return false;
    if (t >= totplookup.size()) return false;
    if (totplookup[Nat64.toNat(Int64.toNat64(Int64.fromInt(t)))] == code) return true;
    if (t == 0) return false;
    if (totplookup[Nat64.toNat(Int64.toNat64(Int64.fromInt(t - 1)))] == code) return true;
    return false;
  };
  func nextToken() : ?TokenIndex {
    var a = List.pop(_tokensForClaimList);
    _tokensForClaimList := a.1;
    a.0;
  };
  public shared (msg) func claim(code : Text) : async Result.Result<(TokenIndex, Bool), Text> {
    return #err("The drop has ended!");
    let claimer = AID.fromPrincipal(msg.caller, null);
    switch (_claim.get(msg.caller)) {
      case (?token) {
        var owner = Option.unwrap(_registry.get(token));
        return #ok((token, (owner == claimer)));
      };
      case (_) {};
    };
    //if (code.size() != 6) return #err("Invalid code!");
    if (Time.now() >= 1636063200000000000) return #err("The drop has ended!");
    if (List.size(_tokensForClaimList) == 0) return #err("There are no more NFTs left!");
    //if (checkTOTP(code) == false) return #err("Your code is invalid - please rescan the QR code!");
    var token = Option.unwrap(nextToken());
    _transferTokenToUser(token, claimer);
    _claimed += 1;
    _claim.put(msg.caller, token);
    #ok((token, true));
  };

  public shared (msg) func heartbeat_external() : async () {
    if (_runHeartbeat == true) {
      try {
        await cronDisbursements();
        await cronSettlements();
        await cronCapEvents();
      } catch (e) {
        _runHeartbeat := false;
      };
    };
  };
  public query func isHeartbeatRunning() : async Bool {
    _runHeartbeat;
  };
  public query func heartbeat_pending() : async [(Text, Nat)] {
    [
      ("Disbursements", List.size(_disbursements)),
      ("CAP Events", List.size(_capEvents)),
      // ("Expired Payment Settlements", unlockedSettlements().size())
    ];
  };

  //Listings
  //EXTv2 SALE
  func _natToSubAccount(n : Nat) : SubAccount {
    let n_byte = func(i : Nat) : Nat8 {
      assert (i < 32);
      let shift : Nat = 8 * (32 - 1 - i);
      Nat8.fromIntWrap(n / 2 ** shift);
    };
    Array.tabulate<Nat8>(32, n_byte);
  };
  func _getNextSubAccount() : SubAccount {
    var _saOffset = 4294967296;
    _nextSubAccount += 1;
    return _natToSubAccount(_saOffset + _nextSubAccount);
  };
  func _addDisbursement(d : (TokenIndex, AccountIdentifier, SubAccount, Nat64)) : () {
    _disbursements := List.push(d, _disbursements);
  };
  public shared (msg) func lock(tokenid : TokenIdentifier, price : Nat64, address : AccountIdentifier, _subaccountNOTUSED : SubAccount) : async Result.Result<AccountIdentifier, CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(tokenid, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(tokenid));
    };
    let token = ExtCore.TokenIdentifier.getIndex(tokenid);
    if (_isLocked(token)) {
      return #err(#Other("Listing is locked"));
    };
    let subaccount = _getNextSubAccount();
    switch (_tokenListing.get(token)) {
      case (?listing) {
        if (listing.price != price) {
          return #err(#Other("Price has changed!"));
        } else {
          let paymentAddress : AccountIdentifier = AID.fromPrincipal(Principal.fromActor(this), ?subaccount);
          _tokenListing.put(
            token,
            {
              seller = listing.seller;
              price = listing.price;
              locked = ?(Time.now() + ESCROWDELAY);
            },
          );
          switch (_tokenSettlement.get(token)) {
            case (?settlement) {
              let resp : Result.Result<(), CommonError> = await settle(tokenid);
              switch (resp) {
                case (#ok) {
                  return #err(#Other("Listing has sold"));
                };
                case (#err _) {
                  //Atomic protection
                  if (Option.isNull(_tokenListing.get(token))) return #err(#Other("Listing has sold"));
                };
              };
            };
            case (_) {};
          };
          _tokenSettlement.put(
            token,
            {
              seller = listing.seller;
              price = listing.price;
              subaccount = subaccount;
              buyer = address;
            },
          );
          return #ok(paymentAddress);
        };
      };
      case (_) {
        return #err(#Other("No listing!"));
      };
    };
  };
  public shared (msg) func settle(tokenid : TokenIdentifier) : async Result.Result<(), CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(tokenid, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(tokenid));
    };
    let token = ExtCore.TokenIdentifier.getIndex(tokenid);
    switch (_tokenSettlement.get(token)) {
      case (?settlement) {
        let response : ICPTs = await LEDGER_CANISTER.account_balance_dfx({
          account = AID.fromPrincipal(Principal.fromActor(this), ?settlement.subaccount);
        });
        switch (_tokenSettlement.get(token)) {
          case (?settlement) {
            if (response.e8s >= settlement.price) {
              switch (_registry.get(token)) {
                case (?token_owner) {
                  var bal : Nat64 = settlement.price - (10000 * Nat64.fromNat(salesFees.size() + 1));
                  var rem = bal;
                  for (f in salesFees.vals()) {
                    var _fee : Nat64 = bal * f.1 / 100000;
                    _addDisbursement((token, f.0, settlement.subaccount, _fee));
                    rem := rem - _fee : Nat64;
                  };
                  _addDisbursement((token, token_owner, settlement.subaccount, rem));
                  _capAddSale(token, token_owner, settlement.buyer, settlement.price);
                  _transferTokenToUser(token, settlement.buyer);
                  _transactions := Array.append(_transactions, [{ token = tokenid; seller = settlement.seller; price = settlement.price; buyer = settlement.buyer; time = Time.now() }]);
                  _tokenListing.delete(token);
                  _tokenSettlement.delete(token);
                  return #ok();
                };
                case (_) {
                  return #err(#InvalidToken(tokenid));
                };
              };
            } else {
              if (_isLocked(token)) {
                return #err(#Other("Insufficient funds sent"));
              } else {
                _tokenSettlement.delete(token);
                return #err(#Other("Nothing to settle"));
              };
            };
          };
          case (_) return #err(#Other("Nothing to settle"));
        };
      };
      case (_) return #err(#Other("Nothing to settle"));
    };
  };
  public shared (msg) func list(request : ListRequest) : async Result.Result<(), CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(request.token, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(request.token));
    };
    let token = ExtCore.TokenIdentifier.getIndex(request.token);
    if (_isLocked(token)) {
      return #err(#Other("Listing is locked"));
    };
    switch (_tokenSettlement.get(token)) {
      case (?settlement) {
        let resp : Result.Result<(), CommonError> = await settle(request.token);
        switch (resp) {
          case (#ok) return #err(#Other("Listing as sold"));
          case (#err _) {};
        };
      };
      case (_) {};
    };
    let owner = AID.fromPrincipal(msg.caller, request.from_subaccount);
    switch (_registry.get(token)) {
      case (?token_owner) {
        if (AID.equal(owner, token_owner) == false) {
          return #err(#Other("Not authorized"));
        };
        switch (request.price) {
          case (?price) {
            _tokenListing.put(
              token,
              {
                seller = msg.caller;
                price = price;
                locked = null;
              },
            );
          };
          case (_) {
            _tokenListing.delete(token);
          };
        };
        if (Option.isSome(_tokenSettlement.get(token))) {
          _tokenSettlement.delete(token);
        };
        return #ok;
      };
      case (_) {
        return #err(#InvalidToken(request.token));
      };
    };
  };
  public shared (msg) func cronDisbursements() : async () {
    var _cont : Bool = true;
    while (_cont) {
      var last = List.pop(_disbursements);
      switch (last.0) {
        case (?d) {
          _disbursements := last.1;
          try {
            var bh = await LEDGER_CANISTER.send_dfx({
              memo = Encoding.BigEndian.toNat64(Blob.toArray(Principal.toBlob(Principal.fromText(ExtCore.TokenIdentifier.fromPrincipal(Principal.fromActor(this), d.0)))));
              amount = { e8s = d.3 };
              fee = { e8s = 10000 };
              from_subaccount = ?d.2;
              to = d.1;
              created_at_time = null;
            });
          } catch (e) {
            _disbursements := List.push(d, _disbursements);
            _cont := false;
          };
        };
        case (_) {
          _cont := false;
        };
      };
    };
  };
  public shared (msg) func cronSettlements() : async () {
    for (settlement in unlockedSettlements().vals()) {
      ignore (settle(ExtCore.TokenIdentifier.fromPrincipal(Principal.fromActor(this), settlement.0)));
    };
  };

  //Cap
  func _capAddTransfer(token : TokenIndex, from : AccountIdentifier, to : AccountIdentifier) : () {
    let event : CapIndefiniteEvent = {
      operation = "transfer";
      details = [
        ("to", #Text(to)),
        ("from", #Text(from)),
        ("token", #Text(ExtCore.TokenIdentifier.fromPrincipal(Principal.fromActor(this), token))),
        ("balance", #U64(1)),
      ];
      caller = Principal.fromActor(this);
    };
    _capAdd(event);
  };
  func _capAddSale(token : TokenIndex, from : AccountIdentifier, to : AccountIdentifier, amount : Nat64) : () {
    let event : CapIndefiniteEvent = {
      operation = "sale";
      details = [
        ("to", #Text(to)),
        ("from", #Text(from)),
        ("token", #Text(ExtCore.TokenIdentifier.fromPrincipal(Principal.fromActor(this), token))),
        ("balance", #U64(1)),
        ("price_decimals", #U64(8)),
        ("price_currency", #Text("ICP")),
        ("price", #U64(amount)),
      ];
      caller = Principal.fromActor(this);
    };
    _capAdd(event);
  };
  func _capAddMint(token : TokenIndex, from : AccountIdentifier, to : AccountIdentifier, amount : ?Nat64) : () {
    let event : CapIndefiniteEvent = switch (amount) {
      case (?a) {
        {
          operation = "mint";
          details = [
            ("to", #Text(to)),
            ("from", #Text(from)),
            ("token", #Text(ExtCore.TokenIdentifier.fromPrincipal(Principal.fromActor(this), token))),
            ("balance", #U64(1)),
            ("price_decimals", #U64(8)),
            ("price_currency", #Text("ICP")),
            ("price", #U64(a)),
          ];
          caller = Principal.fromActor(this);
        };
      };
      case (_) {
        {
          operation = "mint";
          details = [
            ("to", #Text(to)),
            ("from", #Text(from)),
            ("token", #Text(ExtCore.TokenIdentifier.fromPrincipal(Principal.fromActor(this), token))),
            ("balance", #U64(1)),
          ];
          caller = Principal.fromActor(this);
        };
      };
    };
    _capAdd(event);
  };
  func _capAdd(event : CapIndefiniteEvent) : () {
    _capEvents := List.push(event, _capEvents);
  };
  public shared (msg) func cronCapEvents() : async () {
    var _cont : Bool = true;
    while (_cont) {
      var last = List.pop(_capEvents);
      switch (last.0) {
        case (?event) {
          _capEvents := last.1;
          try {
            ignore await CapService.insert(event);
          } catch (e) {
            _capEvents := List.push(event, _capEvents);
            _cont := false;
          };
        };
        case (_) {
          _cont := false;
        };
      };
    };
  };
  public shared (msg) func initCap() : async () {
    if (Option.isNull(capRootBucketId)) {
      try {
        capRootBucketId := await CapService.handshake(Principal.toText(Principal.fromActor(this)), 1_000_000_000_000);
      } catch e {};
    };
  };
  private stable var historicExportHasRun : Bool = false;
  public shared (msg) func historicExport() : async Bool {
    if (historicExportHasRun == false) {
      var events : [CapEvent] = [];
      for (tx in _transactions.vals()) {
        let event : CapEvent = {
          time = Int64.toNat64(Int64.fromInt(tx.time));
          operation = "sale";
          details = [
            ("to", #Text(tx.buyer)),
            ("from", #Text(Principal.toText(tx.seller))),
            ("token", #Text(tx.token)),
            ("balance", #U64(1)),
            ("price_decimals", #U64(8)),
            ("price_currency", #Text("ICP")),
            ("price", #U64(tx.price)),
          ];
          caller = Principal.fromActor(this);
        };
        events := Array.append(events, [event]);
      };
      try {
        ignore (await CapService.migrate(events));
        historicExportHasRun := true;
      } catch (e) {};
    };
    historicExportHasRun;
  };
  public shared (msg) func adminKillHeartbeat() : async () {
    assert (msg.caller == _minter);
    _runHeartbeat := false;
  };
  public shared (msg) func adminStartHeartbeat() : async () {
    assert (msg.caller == _minter);
    _runHeartbeat := true;
  };
  public shared (msg) func adminRefund(password : Text, escrow : AccountIdentifier, sendto : AccountIdentifier) : async Text {
    assert (password == "PC%4W3@ZL3WZ5R$U!f088pjI");
    assert (msg.caller == Principal.fromText("4opr7-aaepd-uw2ok-lpt52-bi5to-nguta-7r7gr-gx57i-tnzlw-ewjid-qae") or msg.caller == Principal.fromText("gt6pl-emtcy-selas-w57zx-kyok4-5ofde-vf5nq-6773c-2t6bv-bsems-tqe") or msg.caller == Principal.fromText("2sr56-kadmk-wfai7-753z7-yo6rd-a4d2f-ghedf-wrkvd-rav3s-2vcfm-wae") or msg.caller == Principal.fromText("aba3c-mjh2y-sp47u-cpa7l-fsiga-5dg2p-wqubj-ecp7c-zwrvc-724ko-wae"));
    switch (_getSubAccountForAddress(escrow)) {
      case (?sa) {
        let response : ICPTs = await LEDGER_CANISTER.account_balance_dfx({
          account = escrow;
        });
        if (response.e8s > 10000) {
          var bh = await LEDGER_CANISTER.send_dfx({
            memo = 0;
            amount = { e8s = (response.e8s - 10000) };
            fee = { e8s = 10000 };
            from_subaccount = ?sa;
            to = sendto;
            created_at_time = null;
          });
          return "FOUND ADDRESS AND SENT";
        };
        return "NOT ENOUGH FUNDS IN ADDRESS";
      };
      case (_) {};
    };
    return "NOT VALID ESCROW ADDRESS";
  };
  func _getSubAccountForAddress(a : AccountIdentifier) : ?SubAccount {
    var s : Nat = 4294967296;
    while (s < (4294967296 + _nextSubAccount)) {
      var sa = _natToSubAccount(s);
      if (AID.fromPrincipal(Principal.fromActor(this), ?sa) == a) return ?sa;
      s += 1;
    };
    return null;
  };
  public shared (msg) func setMinter(minter : Principal) : async () {
    assert (msg.caller == _minter);
    _minter := minter;
  };
  public shared (msg) func mintNFT(request : MintRequest) : async TokenIndex {
    assert (msg.caller == _minter);
    let receiver = ExtCore.User.toAID(request.to);
    let token = _nextTokenId;
    let md : Metadata = #nonfungible({
      metadata = request.metadata;
    });
    _tokenMetadata.put(token, md);
    _transferTokenToUser(token, receiver);
    _supply := _supply + 1;
    _nextTokenId := _nextTokenId + 1;
    token;
  };

  public shared (msg) func transfer(request : TransferRequest) : async TransferResponse {
    if (request.amount != 1) {
      return #err(#Other("Must use amount of 1"));
    };
    if (ExtCore.TokenIdentifier.isPrincipal(request.token, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(request.token));
    };
    let token = ExtCore.TokenIdentifier.getIndex(request.token);
    if (Option.isSome(_tokenListing.get(token))) {
      return #err(#Other("This token is currently listed for sale!"));
    };
    let owner = ExtCore.User.toAID(request.from);
    let spender = AID.fromPrincipal(msg.caller, request.subaccount);
    let receiver = ExtCore.User.toAID(request.to);
    if (AID.equal(owner, spender) == false) {
      return #err(#Unauthorized(spender));
    };
    switch (_registry.get(token)) {
      case (?token_owner) {
        if (AID.equal(owner, token_owner) == false) {
          return #err(#Unauthorized(owner));
        };
        if (request.notify) {
          switch (ExtCore.User.toPrincipal(request.to)) {
            case (?canisterId) {
              //Do this to avoid atomicity issue
              _removeTokenFromUser(token);
              let notifier : NotifyService = actor (Principal.toText(canisterId));
              try {
                switch (await notifier.tokenTransferNotification(request.token, request.from, request.amount, request.memo)) {
                  case (?balance) {
                    if (balance == 1) {
                      _transferTokenToUser(token, receiver);
                      _capAddTransfer(token, owner, receiver);
                      return #ok(request.amount);
                    } else {
                      //Refund
                      _transferTokenToUser(token, owner);
                      return #err(#Rejected);
                    };
                  };
                  case (_) {
                    //Refund
                    _transferTokenToUser(token, owner);
                    return #err(#Rejected);
                  };
                };
              } catch (e) {
                _transferTokenToUser(token, owner);
                return #err(#CannotNotify(receiver));
              };
            };
            case (_) {
              return #err(#CannotNotify(receiver));
            };
          };
        } else {
          _transferTokenToUser(token, receiver);
          _capAddTransfer(token, owner, receiver);
          return #ok(request.amount);
        };
      };
      case (_) {
        return #err(#InvalidToken(request.token));
      };
    };
  };

  public query func getMinter() : async Principal {
    _minter;
  };
  public query func extensions() : async [Extension] {
    EXTENSIONS;
  };
  public query func balance(request : BalanceRequest) : async BalanceResponse {
    if (ExtCore.TokenIdentifier.isPrincipal(request.token, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(request.token));
    };
    let token = ExtCore.TokenIdentifier.getIndex(request.token);
    let aid = ExtCore.User.toAID(request.user);
    switch (_registry.get(token)) {
      case (?token_owner) {
        if (AID.equal(aid, token_owner) == true) {
          return #ok(1);
        } else {
          return #ok(0);
        };
      };
      case (_) {
        return #err(#InvalidToken(request.token));
      };
    };
  };
  public query func bearer(token : TokenIdentifier) : async Result.Result<AccountIdentifier, CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(token));
    };
    let tokenind = ExtCore.TokenIdentifier.getIndex(token);
    switch (_getBearer(tokenind)) {
      case (?token_owner) {
        return #ok(token_owner);
      };
      case (_) {
        return #err(#InvalidToken(token));
      };
    };
  };
  public query func supply(token : TokenIdentifier) : async Result.Result<Balance, CommonError> {
    #ok(_supply);
  };
  public query func getRegistry() : async [(TokenIndex, AccountIdentifier)] {
    Iter.toArray(_registry.entries());
  };
  public query func getTokens() : async [(TokenIndex, Metadata)] {
    Iter.toArray(_tokenMetadataQuickIndex.entries());
  };
  public query func tokens(aid : AccountIdentifier) : async Result.Result<[TokenIndex], CommonError> {
    switch (_owners.get(aid)) {
      case (?tokens) return #ok(tokens);
      case (_) return #err(#Other("No tokens"));
    };
  };

  public query func tokens_ext(aid : AccountIdentifier) : async Result.Result<[(TokenIndex, ?Listing, ?Blob)], CommonError> {
    switch (_owners.get(aid)) {
      case (?tokens) {
        var resp : [(TokenIndex, ?Listing, ?Blob)] = [];
        for (a in tokens.vals()) {
          resp := Array.append(resp, [(a, _tokenListing.get(a), null)]);
        };
        return #ok(resp);
      };
      case (_) return #err(#Other("No tokens"));
    };
  };
  public query func metadata(token : TokenIdentifier) : async Result.Result<Metadata, CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(token));
    };
    let tokenind = ExtCore.TokenIdentifier.getIndex(token);
    switch (_tokenMetadata.get(tokenind)) {
      case (?token_metadata) {
        return #ok(token_metadata);
      };
      case (_) {
        return #err(#InvalidToken(token));
      };
    };
  };
  public query func details(token : TokenIdentifier) : async Result.Result<(AccountIdentifier, ?Listing), CommonError> {
    if (ExtCore.TokenIdentifier.isPrincipal(token, Principal.fromActor(this)) == false) {
      return #err(#InvalidToken(token));
    };
    let tokenind = ExtCore.TokenIdentifier.getIndex(token);
    switch (_getBearer(tokenind)) {
      case (?token_owner) {
        return #ok((token_owner, _tokenListing.get(tokenind)));
      };
      case (_) {
        return #err(#InvalidToken(token));
      };
    };
  };

  //Listings
  public query func transactions() : async [Transaction] {
    _transactions;
  };
  public query func settlements() : async [(TokenIndex, AccountIdentifier, Nat64)] {
    //Lock to admin?
    var result : [(TokenIndex, AccountIdentifier, Nat64)] = [];
    for ((token, listing) in _tokenListing.entries()) {
      if (_isLocked(token)) {
        switch (_tokenSettlement.get(token)) {
          case (?settlement) {
            result := Array.append(result, [(token, AID.fromPrincipal(settlement.seller, ?settlement.subaccount), settlement.price)]);
          };
          case (_) {};
        };
      };
    };
    result;
  };
  public query (msg) func payments() : async ?[SubAccount] {
    _payments.get(msg.caller);
  };
  public query func listings() : async [(TokenIndex, Listing, Metadata)] {
    var results : [(TokenIndex, Listing, Metadata)] = [];
    for (a in _tokenListing.entries()) {
      results := Array.append(results, [(a.0, a.1, #nonfungible({ metadata = null }))]);
    };
    results;
  };
  public query (msg) func allSettlements() : async [(TokenIndex, Settlement)] {
    Iter.toArray(_tokenSettlement.entries());
  };
  public query (msg) func allPayments() : async [(Principal, [SubAccount])] {
    Iter.toArray(_payments.entries());
  };
  func unlockedSettlements() : [(TokenIndex, Settlement)] {
    Array.filter<(TokenIndex, Settlement)>(
      Iter.toArray(_tokenSettlement.entries()),
      func(a : (TokenIndex, Settlement)) : Bool {
        return (_isLocked(a.0) == false);
      },
    );
  };

  public shared (msg) func clearPayments(seller : Principal, payments : [SubAccount]) : async () {
    var removedPayments : [SubAccount] = payments;
    for (p in payments.vals()) {
      let response : ICPTs = await LEDGER_CANISTER.account_balance_dfx({
        account = AID.fromPrincipal(seller, ?p);
      });
      if (response.e8s < 10_000) {
        removedPayments := Array.append(removedPayments, [p]);
      };
    };
    switch (_payments.get(seller)) {
      case (?sellerPayments) {
        var newPayments : [SubAccount] = [];
        for (p in sellerPayments.vals()) {
          if (
            Option.isNull(
              Array.find(
                removedPayments,
                func(a : SubAccount) : Bool {
                  Array.equal(a, p, Nat8.equal);
                },
              )
            )
          ) {
            newPayments := Array.append(newPayments, [p]);
          };
        };
        _payments.put(seller, newPayments);
      };
      case (_) {};
    };
  };
  public query func stats() : async (Nat64, Nat64, Nat64, Nat64, Nat, Nat, Nat) {
    var res : (Nat64, Nat64, Nat64) = Array.foldLeft<Transaction, (Nat64, Nat64, Nat64)>(
      _transactions,
      (0, 0, 0),
      func(b : (Nat64, Nat64, Nat64), a : Transaction) : (Nat64, Nat64, Nat64) {
        var total : Nat64 = b.0 + a.price;
        var high : Nat64 = b.1;
        var low : Nat64 = b.2;
        if (high == 0 or a.price > high) high := a.price;
        if (low == 0 or a.price < low) low := a.price;
        (total, high, low);
      },
    );
    var floor : Nat64 = 0;
    for (a in _tokenListing.entries()) {
      if (floor == 0 or a.1.price < floor) floor := a.1.price;
    };
    (res.0, res.1, res.2, floor, _tokenListing.size(), _registry.size(), _transactions.size());
  };

  //HTTP
  type HeaderField = (Text, Text);
  type HttpResponse = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    streaming_strategy : ?HttpStreamingStrategy;
  };
  type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };
  type HttpStreamingCallbackToken = {
    content_encoding : Text;
    index : Nat;
    key : Text;
    sha256 : ?Blob;
  };

  type HttpStreamingStrategy = {
    #Callback : {
      callback : query (HttpStreamingCallbackToken) -> async (HttpStreamingCallbackResponse);
      token : HttpStreamingCallbackToken;
    };
  };

  type HttpStreamingCallbackResponse = {
    body : Blob;
    token : ?HttpStreamingCallbackToken;
  };
  let NOT_FOUND : HttpResponse = {
    status_code = 404;
    headers = [];
    body = Blob.fromArray([]);
    streaming_strategy = null;
  };
  let BAD_REQUEST : HttpResponse = {
    status_code = 400;
    headers = [];
    body = Blob.fromArray([]);
    streaming_strategy = null;
  };
  public query func http_request(request : HttpRequest) : async HttpResponse {
    let path = Iter.toArray(Text.tokens(request.url, #text("/")));
    switch (_getParam(request.url, "tokenid")) {
      case (?tokenid) {
        if (ExtCore.TokenIdentifier.isPrincipal(tokenid, Principal.fromActor(this)) == true) {
          switch (_getTokenData(ExtCore.TokenIdentifier.getIndex(tokenid))) {
            case (?img) {
              return {
                status_code = 200;
                headers = [("content-type", "image/svg+xml"), ("cache-control", "public, max-age=15552000")];
                body = img;
                streaming_strategy = null;
              };
            };
            case (_) {};
          };
        };
      };
      case (_) {};
    };
    switch (_getParam(request.url, "index")) {
      case (?index) {
        switch (_getTokenData(_textToNat32(index))) {
          case (?img) {
            return {
              status_code = 200;
              headers = [("content-type", "image/svg+xml"), ("cache-control", "public, max-age=15552000")];
              body = img;
              streaming_strategy = null;
            };
          };
          case (_) {};
        };
      };
      case (_) {};
    };

    //Just show index
    var soldValue : Nat = Nat64.toNat(Array.foldLeft<Transaction, Nat64>(_transactions, 0, func(b : Nat64, a : Transaction) : Nat64 { b + a.price }));
    var avg : Nat = if (_transactions.size() > 0) {
      soldValue / _transactions.size();
    } else {
      0;
    };
    return {
      status_code = 200;
      headers = [("content-type", "text/plain")];
      body = Text.encodeUtf8(
        "MOTOKO DAY DROP NFT\n" #
        "EXT by ToniqLabs Inc.\n" #
        "---\n" #
        "Claimable NFTs:                           " # debug_show (List.size(_tokensForClaimList)) # "\n" #
        "Claimed NFTs:                             " # debug_show (3000 - List.size(_tokensForClaimList) : Nat) # "\n" #
        "TOTP Codes:                               " # debug_show (totplookup.size()) # "\n" #
        "---\n" #
        "Cycle Balance:                            ~" # debug_show (Cycles.balance() / 1000000000000) # "T\n" #
        "Minted NFTs:                              " # debug_show (_registry.size()) # "\n" #
        "Assets:                                   " # debug_show (_tokenMetadata.size()) # "\n" #
        "Marketplace Listings:                     " # debug_show (_tokenListing.size()) # "\n" #
        "Sold via Marketplace:                     " # debug_show (_transactions.size()) # "\n" #
        "Sold via Marketplace in ICP:              " # _displayICP(soldValue) # "\n" #
        "Average Price ICP Via Marketplace:        " # _displayICP(avg) # "\n" #
        "Admin:                                    " # debug_show (_minter) # "\n"
      );
      streaming_strategy = null;
    };
  };
  private func _getTokenData(tokenind : TokenIndex) : ?Blob {
    switch (_tokenMetadata.get(tokenind)) {
      case (?token_metadata) {
        switch (token_metadata) {
          case (#fungible data) return null;
          case (#nonfungible data) return data.metadata;
        };
      };
      case (_) {
        return null;
      };
    };
    return null;
  };
  private func _getParam(url : Text, param : Text) : ?Text {
    var _s : Text = url;
    Iter.iterate<Text>(
      Text.split(_s, #text("/")),
      func(x, _i) {
        _s := x;
      },
    );
    Iter.iterate<Text>(
      Text.split(_s, #text("?")),
      func(x, _i) {
        if (_i == 1) _s := x;
      },
    );
    var t : ?Text = null;
    var found : Bool = false;
    Iter.iterate<Text>(
      Text.split(_s, #text("&")),
      func(x, _i) {
        if (found == false) {
          Iter.iterate<Text>(
            Text.split(x, #text("=")),
            func(y, _ii) {
              if (_ii == 0) {
                if (Text.equal(y, param)) found := true;
              } else if (found == true) t := ?y;
            },
          );
        };
      },
    );
    return t;
  };
  private func _streamContent(id : Text, idx : Nat, data : [Blob]) : (Blob, ?HttpStreamingCallbackToken) {
    let payload = data[idx];
    let size = data.size();

    if (idx + 1 == size) {
      return (payload, null);
    };

    return (
      payload,
      ?{
        content_encoding = "gzip";
        index = idx + 1;
        sha256 = null;
        key = id;
      },
    );
  };

  //Internal cycle management - good general case
  public func acceptCycles() : async () {
    let available = Cycles.available();
    let accepted = Cycles.accept(available);
    assert (accepted == available);
  };
  public query func availableCycles() : async Nat {
    return Cycles.balance();
  };

  //Private
  func _textToNat32(t : Text) : Nat32 {
    var reversed : [Nat32] = [];
    for (c in t.chars()) {
      assert (Char.isDigit(c));
      reversed := Array.append([Char.toNat32(c) -48], reversed);
    };
    var total : Nat32 = 0;
    var place : Nat32 = 1;
    for (v in reversed.vals()) {
      total += (v * place);
      place := place * 10;
    };
    total;
  };
  func _removeTokenFromUser(tindex : TokenIndex) : () {
    let owner : ?AccountIdentifier = _getBearer(tindex);
    _registry.delete(tindex);
    switch (owner) {
      case (?o) _removeFromUserTokens(tindex, o);
      case (_) {};
    };
  };
  func _transferTokenToUser(tindex : TokenIndex, receiver : AccountIdentifier) : () {
    let owner : ?AccountIdentifier = _getBearer(tindex);
    _registry.put(tindex, receiver);
    switch (owner) {
      case (?o) _removeFromUserTokens(tindex, o);
      case (_) {};
    };
    _addToUserTokens(tindex, receiver);
  };
  func _removeFromUserTokens(tindex : TokenIndex, owner : AccountIdentifier) : () {
    switch (_owners.get(owner)) {
      case (?ownersTokens) _owners.put(owner, Array.filter(ownersTokens, func(a : TokenIndex) : Bool { (a != tindex) }));
      case (_) ();
    };
  };
  func _addToUserTokens(tindex : TokenIndex, receiver : AccountIdentifier) : () {
    let ownersTokensNew : [TokenIndex] = switch (_owners.get(receiver)) {
      case (?ownersTokens) Array.append(ownersTokens, [tindex]);
      case (_) [tindex];
    };
    _owners.put(receiver, ownersTokensNew);
  };
  func _getBearer(tindex : TokenIndex) : ?AccountIdentifier {
    _registry.get(tindex);
  };
  func _isLocked(token : TokenIndex) : Bool {
    switch (_tokenListing.get(token)) {
      case (?listing) {
        switch (listing.locked) {
          case (?time) {
            if (time > Time.now()) {
              return true;
            } else {
              return false;
            };
          };
          case (_) {
            return false;
          };
        };
      };
      case (_) return false;
    };
  };
  func _displayICP(amt : Nat) : Text {
    debug_show (amt / 100000000) # "." # debug_show ((amt % 100000000) / 1000000) # " ICP";
  };
};

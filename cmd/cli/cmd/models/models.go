package models

const (
	// General CLI command constants

	CCommandCreateWallet          string = "createwallet"
	CCommandEncryptWallet         string = "encryptwallet"
	CCommandGetBCInfo             string = "getblockchaininfo"
	CCommandGetInfo               string = "getinfo"
	CCommandGetStakingInfo        string = "getstakinginfo"
	CCommandListReceivedByAddress string = "listreceivedbyaddress"
	CCommandListTransactions      string = "listtransactions"
	CCommandLoadWallet            string = "loadwallet"
	CCommandGetNetworkInfo        string = "getnetworkinfo"
	CCommandGetNewAddress         string = "getnewaddress"
	CCommandGetWalletInfo         string = "getwalletinfo"
	CCommandSendToAddress         string = "sendtoaddress"
	CCommandSetTxFee              string = "settxfee"

	//CCommandMNSyncStatus1 string = "mnsync"
	//CCommandMNSyncStatus2 string = "status"
	//CCommandDumpHDInfo    string = "dumphdinfo" // ./divi-cli dumphdinfo

	CRPCUser     string = "rpcuser"
	CRPCPassword string = "rpcpassword"
)

// ProjectType - To allow external to determine what kind of wallet we are working with.
type ProjectType int

const (
	PTDivi ProjectType = iota
	PTPhore
	PTPIVX
	PTTrezarcoin
	PTFeathercoin
	PTVertcoin
	PTGroestlcoin
	PTScala
	PTDeVault
	PTReddCoin
	PTRapids
	PTDigiByte
	PTDenarius
	PTSyscoin
	PTBitcoinPlus
	PTPeercoin
	PTPrimecoin
	PTLitecoinPlus
)

type GenericResponse struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type CoinAuth struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

type WEType int

const (
	WETUnencrypted WEType = iota
	WETLocked
	WETUnlocked
	WETUnlockedForStaking
	WETUnknown
)

// WLSType - Wallet loading status type, what stage are we with the wallet loading?
type WLSType int

const (
	WLSTUnknown WLSType = iota
	WLSTReady
	WLSTLoading
	WLSTRescanning
	WLSTRewinding
	WLSTVerifying
	WLSTCalculatingMoneySupply
	WLSTWaitingForResponse
)

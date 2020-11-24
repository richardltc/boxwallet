package bend

const (
	CCoinNameReddCoin string = "ReddCoin"

	CReddCoinCoreVersion string = "3.10.3"

	CDFReddCoinRPi     string = "reddcoin-" + CReddCoinCoreVersion + "-arm64.tar.gz"
	CDFReddCoinLinux   string = "reddcoin-" + CReddCoinCoreVersion + "-linux64.tar.gz"
	CDFReddCoinWindows string = "reddcoin-" + CReddCoinCoreVersion + "-win64.zip"

	CReddCoinExtractedDirLinux = "reddcoin-" + CReddCoinCoreVersion + "/"

	CDownloadURLReddCoin string = "https://download.reddcoin.com/bin/reddcoin-core-" + CReddCoinCoreVersion + "/"
	CReddCoinHomeDir     string = ".reddcoin"
	CReddCoinHomeDirWin  string = "REDDCOIN"

	CReddCoinConfFile   string = "reddcoin.conf"
	CReddCoinCliFile    string = "reddcoin-cli"
	CReddCoinCliFileWin string = "reddcoin-cli.exe"
	CReddCoinDFile      string = "reddcoind"
	CReddCoinDFileWin   string = "reddcoind.exe"
	CReddCoinTxFile     string = "reddcoin-tx"
	CReddCoinTxFileWin  string = "reddcoin-tx.exe"

	cReddCoinRPCUser string = "reddcoinrpc"
	CReddCoinRPCPort string = "45443"
)

type RDDBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type RDDNetworkInfoRespStruct struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Timeoffset      int    `json:"timeoffset"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name      string `json:"name"`
			Limited   bool   `json:"limited"`
			Reachable bool   `json:"reachable"`
			Proxy     string `json:"proxy"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Localaddresses []interface{} `json:"localaddresses"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type RDDWalletInfoRespStruct struct {
	Result struct {
		Walletversion int     `json:"walletversion"`
		Balance       float64 `json:"balance"`
		Txcount       int     `json:"txcount"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

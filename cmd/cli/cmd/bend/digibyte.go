package bend

const (
	CCoinNameDigiByte   string = "DigiByte"
	CCoinAbbrevDigiByte string = "DGB"

	CDigiByteCoreVersion string = "7.17.2"
	CDFDigiByteArm64     string = "digibyte-" + CDigiByteCoreVersion + "-aarch64-linux-gnu.tar.gz"
	CDFDigiByteLinux     string = "digibyte-" + CDigiByteCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFDigiByteWindows   string = "digibyte-" + CDigiByteCoreVersion + "-win64.zip"

	CDigiByteExtractedDirLinux   = "digibyte-" + CDigiByteCoreVersion + "/"
	CDigiByteExtractedDirWindows = "digibyte-" + CDigiByteCoreVersion + "\\"

	CDownloadURLDigiByte string = "https://github.com/digibyte/digibyte/releases/download/v" + CDigiByteCoreVersion + "/"

	CDigiByteHomeDir    string = ".digibyte"
	CDigiByteHomeDirWin string = "DIGIBYTE"

	CDigiByteConfFile   string = "digibyte.conf"
	CDigiByteCliFile    string = "digibyte-cli"
	CDigiByteCliFileWin string = "digibyte-cli.exe"
	CDigiByteDFile      string = "digibyted"
	CDigiByteDFileWin   string = "digibyted.exe"
	CDigiByteTxFile     string = "digibyte-tx"
	CDigiByteTxFileWin  string = "digibyte-tx.exe"

	cDigiByteRPCUser string = "digibyterpc"
	CDigiByteRPCPort string = "14022"
)

// No GetInfo in DigiByte
// This call was removed in version 6.16.0. Use the appropriate fields from:
// getblockchaininfo: blocks, difficulty, chain
// getnetworkinfo: version, protocolversion, timeoffset, connections, proxy, relayfee, warnings
// getwalletinfo: balance, keypoololdest, keypoolsize, paytxfee, unlocked_until, walletversion

type DGBBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Mediantime           int     `json:"mediantime"`
		Verificationprogress float64 `json:"verificationprogress"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		Chainwork            string  `json:"chainwork"`
		SizeOnDisk           int     `json:"size_on_disk"`
		Pruned               bool    `json:"pruned"`
		Difficulties         struct {
			Scrypt float64 `json:"scrypt"`
		} `json:"difficulties"`
		Softforks     []interface{} `json:"softforks"`
		Bip9Softforks struct {
			Csv struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"csv"`
			Segwit struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"segwit"`
			Nversionbips struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"nversionbips"`
			Reservealgo struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"reservealgo"`
			Odo struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
				Since     int    `json:"since"`
			} `json:"odo"`
		} `json:"bip9_softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBGetNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DGBListReceivedByAddressRespStruct struct {
	Result []struct {
		Address       string        `json:"address"`
		Account       string        `json:"account"`
		Amount        float64       `json:"amount"`
		Confirmations int           `json:"confirmations"`
		Label         string        `json:"label"`
		Txids         []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
type DGBNetworkInfoRespStruct struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Localrelay      bool   `json:"localrelay"`
		Timeoffset      int    `json:"timeoffset"`
		Networkactive   bool   `json:"networkactive"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name                      string `json:"name"`
			Limited                   bool   `json:"limited"`
			Reachable                 bool   `json:"reachable"`
			Proxy                     string `json:"proxy"`
			ProxyRandomizeCredentials bool   `json:"proxy_randomize_credentials"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Incrementalfee float64       `json:"incrementalfee"`
		Localaddresses []interface{} `json:"localaddresses"`
		Warnings       string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBWalletInfoRespStruct struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
		ImmatureBalance       float64 `json:"immature_balance"`
		Txcount               int     `json:"txcount"`
		Keypoololdest         int     `json:"keypoololdest"`
		Keypoolsize           int     `json:"keypoolsize"`
		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
		Paytxfee              float64 `json:"paytxfee"`
		Hdseedid              string  `json:"hdseedid"`
		Hdmasterkeyid         string  `json:"hdmasterkeyid"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

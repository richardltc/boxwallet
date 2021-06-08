package models

type DVTBlockchainInfo struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Mediantime           int     `json:"mediantime"`
		Verificationprogress float64 `json:"verificationprogress"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		Chainwork            string  `json:"chainwork"`
		Coinsupply           float64 `json:"coinsupply"`
		Pruned               bool    `json:"pruned"`
		Warnings             string  `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DeVaultGetInfo struct {
	Result struct {
		Version         int     `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		UnlockedUntil   int     `json:"unlocked_until"`
		Paytxfee        float64 `json:"paytxfee"`
		Relayfee        float64 `json:"relayfee"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DVTListReceivedByAddress struct {
	Result []struct {
		Address       string        `json:"address"`
		Amount        float64       `json:"amount"`
		Confirmations int           `json:"confirmations"`
		Label         string        `json:"label"`
		Txids         []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DVTNetworkInfo struct {
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
		Relayfee         float64       `json:"relayfee"`
		Excessutxocharge float64       `json:"excessutxocharge"`
		Localaddresses   []interface{} `json:"localaddresses"`
		Warnings         string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DVTWalletInfo struct {
	Result struct {
		Walletname         string  `json:"walletname"`
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		Hdchainid          string  `json:"hdchainid"`
		Hdaccountcount     int     `json:"hdaccountcount"`
		Hdaccounts         []struct {
			Hdaccountindex     int `json:"hdaccountindex"`
			Hdexternalkeyindex int `json:"hdexternalkeyindex"`
			Hdinternalkeyindex int `json:"hdinternalkeyindex"`
		} `json:"hdaccounts"`
		UnlockedUntil      int     `json:"unlocked_until"`
		Paytxfee           float64 `json:"paytxfee"`
		PrivateKeysEnabled bool    `json:"private_keys_enabled"`
		HasBlsKeys         bool    `json:"has bls keys"`
		HasLegacyKeys      bool    `json:"has legacy keys"`
		IsBlank            bool    `json:"is blank"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

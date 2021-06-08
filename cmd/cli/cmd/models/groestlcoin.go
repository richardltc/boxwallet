package models

type GRSBlockchainInfo struct {
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
		SizeOnDisk           int     `json:"size_on_disk"`
		Pruned               bool    `json:"pruned"`
		Softforks            struct {
			Bip34 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip34"`
			Bip66 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip66"`
			Bip65 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip65"`
			Csv struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"csv"`
			Segwit struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"segwit"`
		} `json:"softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type GRSListReceivedByAddress struct {
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

type GRSNetworkInfo struct {
	Result struct {
		Version            int      `json:"version"`
		Subversion         string   `json:"subversion"`
		Protocolversion    int      `json:"protocolversion"`
		Localservices      string   `json:"localservices"`
		Localservicesnames []string `json:"localservicesnames"`
		Localrelay         bool     `json:"localrelay"`
		Timeoffset         int      `json:"timeoffset"`
		Networkactive      bool     `json:"networkactive"`
		Connections        int      `json:"connections"`
		Networks           []struct {
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

type GRSNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type GRSWalletInfo struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
		ImmatureBalance       float64 `json:"immature_balance"`
		Txcount               int     `json:"txcount"`
		Keypoololdest         int     `json:"keypoololdest"`
		Keypoolsize           int     `json:"keypoolsize"`
		Hdseedid              string  `json:"hdseedid"`
		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
		Paytxfee              float64 `json:"paytxfee"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
		AvoidReuse            bool    `json:"avoid_reuse"`
		Scanning              bool    `json:"scanning"`
		UnlockedUntil         int     `json:"unlocked_until"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

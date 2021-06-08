package models

type DGBBlockchainInfo struct {
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

type DGBGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DGBListReceivedByAddress struct {
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

type DGBListTransactions struct {
	Result []struct {
		Address         string        `json:"address"`
		Amount          float64       `json:"amount"`
		Vout            int           `json:"vout"`
		Category        string        `json:"category"`
		Confirmations   int           `json:"confirmations"`
		Txid            string        `json:"txid"`
		Walletconflicts []interface{} `json:"walletconflicts"`
		Time            int           `json:"time"`
		Timereceived    int           `json:"timereceived"`
		Blockhash       string        `json:"blockhash,omitempty"`
		Blockindex      int           `json:"blockindex,omitempty"`
		Blocktime       int           `json:"blocktime,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DGBNetworkInfo struct {
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

type DGBWalletInfo struct {
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
		UnlockedUntil         int     `json:"unlocked_until"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

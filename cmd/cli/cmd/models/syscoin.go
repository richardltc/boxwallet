package models

type SYSBlockchainInfo struct {
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
			Taproot struct {
				Type string `json:"type"`
				Bip9 struct {
					Status              string `json:"status"`
					StartTime           int    `json:"start_time"`
					Timeout             int64  `json:"timeout"`
					Since               int    `json:"since"`
					MinActivationHeight int    `json:"min_activation_height"`
				} `json:"bip9"`
				Height int  `json:"height"`
				Active bool `json:"active"`
			} `json:"taproot"`
		} `json:"softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type SYSGetNetworkInfo struct {
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
		ConnectionsIn      int      `json:"connections_in"`
		ConnectionsOut     int      `json:"connections_out"`
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
type SYSGetNewAdddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type SYSCreateWallet struct {
	Result struct {
		Name    string `json:"name"`
		Warning string `json:"warning"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type SYSLoadWallet struct {
	Result struct {
		Name    string `json:"name"`
		Warning string `json:"warning"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
type SYSListReceivedByAddress struct {
	Result []struct {
		Address         string   `json:"address"`
		Account         string   `json:"account"`
		Amount          float64  `json:"amount"`
		Confirmations   int      `json:"confirmations"`
		Bcconfirmations int      `json:"bcconfirmations"`
		Txids           []string `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type SYSListTransactions struct {
	Result []struct {
		InvolvesWatchonly int           `json:"involvesWatchonly"`
		Address           string        `json:"address"`
		Amount            float64       `json:"amount"`
		Vout              int           `json:"vout"`
		Category          string        `json:"category"`
		Account           string        `json:"account"`
		Confirmations     int           `json:"confirmations"`
		Bcconfirmations   int           `json:"bcconfirmations"`
		Generated         bool          `json:"generated"`
		Txid              string        `json:"txid"`
		Walletconflicts   []interface{} `json:"walletconflicts"`
		Time              int           `json:"time"`
		Timereceived      int           `json:"timereceived"`
		Blockhash         string        `json:"blockhash,omitempty"`
		Blockindex        int           `json:"blockindex,omitempty"`
		Blocktime         int           `json:"blocktime,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type SYSWalletInfo struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Format                string  `json:"format"`
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
		Descriptors           bool    `json:"descriptors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

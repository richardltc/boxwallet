package models

type NEXABlockchainInfo struct {
	Result struct {
		Chain                string        `json:"chain"`
		Blocks               int           `json:"blocks"`
		Headers              int           `json:"headers"`
		Bestblockhash        string        `json:"bestblockhash"`
		Difficulty           float64       `json:"difficulty"`
		Mediantime           int           `json:"mediantime"`
		Forktime             string        `json:"forktime"`
		Forkactive           string        `json:"forkactive"`
		Forkactivenextblock  string        `json:"forkactivenextblock"`
		Verificationprogress int           `json:"verificationprogress"`
		Initialblockdownload bool          `json:"initialblockdownload"`
		Chainwork            string        `json:"chainwork"`
		Coinsupply           int64         `json:"coinsupply"`
		SizeOnDisk           int           `json:"size_on_disk"`
		Pruned               bool          `json:"pruned"`
		Softforks            []interface{} `json:"softforks"`
		Bip9Softforks        struct {
		} `json:"bip9_softforks"`
		Bip135Forks struct {
		} `json:"bip135_forks"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type NEXAInfo struct {
	Result struct {
		Version         int     `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Blocks          int     `json:"blocks"`
		Headers         int     `json:"headers"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		PeersGraphene   int     `json:"peers_graphene"`
		PeersXthinblock int     `json:"peers_xthinblock"`
		PeersCmpctblock int     `json:"peers_cmpctblock"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		Paytxfee        int     `json:"paytxfee"`
		Relayfee        int     `json:"relayfee"`
		Status          string  `json:"status"`
		Txindex         string  `json:"txindex"`
		Tokendesc       string  `json:"tokendesc"`
		Tokenmint       string  `json:"tokenmint"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

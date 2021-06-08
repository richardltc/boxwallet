package models

type TZCBlockchainInfo struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Mediantime           int     `json:"mediantime"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
		Pruned               bool    `json:"pruned"`
		Softforks            []struct {
			ID      string `json:"id"`
			Version int    `json:"version"`
			Enforce struct {
				Status   bool `json:"status"`
				Found    int  `json:"found"`
				Required int  `json:"required"`
				Window   int  `json:"window"`
			} `json:"enforce"`
			Reject struct {
				Status   bool `json:"status"`
				Found    int  `json:"found"`
				Required int  `json:"required"`
				Window   int  `json:"window"`
			} `json:"reject"`
		} `json:"softforks"`
		Bip9Softforks struct {
			Csv struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"csv"`
			Segwit struct {
				Status    string `json:"status"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"segwit"`
		} `json:"bip9_softforks"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
type TZCGetInfo struct {
	Result struct {
		Version            int     `json:"version"`
		Protocolversion    int     `json:"protocolversion"`
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		ColdstakingBalance float64 `json:"coldstaking_balance"`
		Newmint            float64 `json:"newmint"`
		Stake              float64 `json:"stake"`
		Blocks             int     `json:"blocks"`
		Moneysupply        float64 `json:"moneysupply"`
		Timeoffset         int     `json:"timeoffset"`
		Connections        int     `json:"connections"`
		Proxy              string  `json:"proxy"`
		Difficulty         struct {
			ProofOfWork  float64 `json:"proof-of-work"`
			ProofOfStake float64 `json:"proof-of-stake"`
		} `json:"difficulty"`
		Testnet       bool    `json:"testnet"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
		UnlockedUntil int     `json:"unlocked_until"`
		Paytxfee      float64 `json:"paytxfee"`
		Relayfee      float64 `json:"relayfee"`
		Errors        string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TZCListReceivedByAddress struct {
	Result []struct {
		Address       string   `json:"address"`
		Account       string   `json:"account"`
		Amount        float64  `json:"amount"`
		Confirmations int      `json:"confirmations"`
		Label         string   `json:"label"`
		Txids         []string `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TZCListTransactions struct {
	Result []struct {
		Account           string        `json:"account"`
		Address           string        `json:"address"`
		Category          string        `json:"category"`
		Amount            float64       `json:"amount"`
		CanStake          bool          `json:"canStake"`
		CanSpend          bool          `json:"canSpend"`
		Label             string        `json:"label"`
		Vout              int           `json:"vout"`
		Confirmations     int           `json:"confirmations"`
		Blockhash         string        `json:"blockhash"`
		Blockindex        int           `json:"blockindex"`
		Blocktime         int           `json:"blocktime"`
		Txid              string        `json:"txid"`
		Walletconflicts   []interface{} `json:"walletconflicts"`
		Time              int           `json:"time"`
		TxComment         string        `json:"tx-comment"`
		Timereceived      int           `json:"timereceived"`
		Bip125Replaceable string        `json:"bip125-replaceable"`
		Generated         bool          `json:"generated,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TZCStakingInfo struct {
	Result struct {
		Enabled          bool    `json:"enabled"`
		Staking          bool    `json:"staking"`
		Errors           string  `json:"errors"`
		Currentblocksize int     `json:"currentblocksize"`
		Currentblocktx   int     `json:"currentblocktx"`
		Difficulty       float64 `json:"difficulty"`
		SearchInterval   int     `json:"search-interval"`
		Weight           int64   `json:"weight"`
		Netstakeweight   int64   `json:"netstakeweight"`
		Stakemintime     int     `json:"stakemintime"`
		Stakeminvalue    float64 `json:"stakeminvalue"`
		Stakecombine     float64 `json:"stakecombine"`
		Stakesplit       float64 `json:"stakesplit"`
		Expectedtime     int     `json:"expectedtime"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type TZCWalletInfo struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		ColdstakingBalance float64 `json:"coldstaking_balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		UnlockedUntil      int     `json:"unlocked_until"`
		Paytxfee           float64 `json:"paytxfee"`
		Hdmasterkeyid      string  `json:"hdmasterkeyid"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

package models

type NAVBlockchainInfo struct {
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
			Id      string `json:"id"`
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
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"csv"`
			Segwit struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"segwit"`
			Communityfund struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"communityfund"`
			CommunityfundAccumulation struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"communityfund_accumulation"`
			Ntpsync struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"ntpsync"`
			Coldstaking struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"coldstaking"`
			ColdstakingPoolFee struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"coldstaking_pool_fee"`
			SpreadCfundAccumulation struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"spread_cfund_accumulation"`
			CommunityfundAmountV2 struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"communityfund_amount_v2"`
			Blsct struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"blsct"`
			Static struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"static"`
			ReducedQuorum struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"reduced_quorum"`
			Votestatecache struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"votestatecache"`
			Consultations struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"consultations"`
			DaoConsensus struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"dao_consensus"`
			ColdstakingV2 struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"coldstaking_v2"`
			DaoSuper struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"dao_super"`
			Exclude struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"exclude"`
			XnavSer struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"xnav_ser"`
			DotNav struct {
				Id        int    `json:"id"`
				Status    string `json:"status"`
				Bit       int    `json:"bit"`
				StartTime int    `json:"startTime"`
				Timeout   int    `json:"timeout"`
			} `json:"dot_nav"`
		} `json:"bip9_softforks"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

type NAVGetInfo struct {
	Result struct {
		Version               int     `json:"version"`
		Protocolversion       int     `json:"protocolversion"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		PrivateBalance        float64 `json:"private_balance"`
		PrivateBalancePending float64 `json:"private_balance_pending"`
		ColdstakingBalance    float64 `json:"coldstaking_balance"`
		Newmint               float64 `json:"newmint"`
		Stake                 float64 `json:"stake"`
		Blocks                int     `json:"blocks"`
		Communityfund         struct {
			Available float64 `json:"available"`
			Locked    float64 `json:"locked"`
		} `json:"communityfund"`
		Publicmoneysupply  string  `json:"publicmoneysupply"`
		Privatemoneysupply string  `json:"privatemoneysupply"`
		Timeoffset         int     `json:"timeoffset"`
		Ntptimeoffset      int     `json:"ntptimeoffset"`
		Connections        int     `json:"connections"`
		Proxy              string  `json:"proxy"`
		Testnet            bool    `json:"testnet"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		UnlockedUntil      int     `json:"unlocked_until"`
		Paytxfee           float64 `json:"paytxfee"`
		Relayfee           float64 `json:"relayfee"`
		Errors             string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

type NAVGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type NAVListReceivedByAddress struct {
	Result []struct {
		Address       string   `json:"address"`
		Account       string   `json:"account"`
		Amount        float64  `json:"amount"`
		Confirmations int      `json:"confirmations"`
		Label         string   `json:"label"`
		Txids         []string `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

type NAVListTransactions struct {
	Result []struct {
		Account           string        `json:"account"`
		Address           string        `json:"address,omitempty"`
		Category          string        `json:"category"`
		Amount            float64       `json:"amount"`
		CanStake          bool          `json:"canStake,omitempty"`
		CanSpend          bool          `json:"canSpend,omitempty"`
		Label             string        `json:"label,omitempty"`
		Vout              int           `json:"vout"`
		Confirmations     int           `json:"confirmations"`
		Blockhash         string        `json:"blockhash"`
		Blockindex        int           `json:"blockindex"`
		Blocktime         int           `json:"blocktime"`
		Txid              string        `json:"txid"`
		Walletconflicts   []interface{} `json:"walletconflicts"`
		Time              int           `json:"time"`
		Timereceived      int           `json:"timereceived"`
		Strdzeel          string        `json:"strdzeel"`
		Bip125Replaceable string        `json:"bip125-replaceable"`
		Memo              string        `json:"memo,omitempty"`
		Fee               float64       `json:"fee,omitempty"`
		Abandoned         bool          `json:"abandoned,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

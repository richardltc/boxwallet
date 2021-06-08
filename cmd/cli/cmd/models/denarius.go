package models

type DenariusBlockchainInfo struct {
	Result struct {
		Chain         string `json:"chain"`
		Blocks        int    `json:"blocks"`
		Bestblockhash string `json:"bestblockhash"`
		Difficulty    struct {
			ProofOfWork  float64 `json:"proof-of-work"`
			ProofOfStake float64 `json:"proof-of-stake"`
		} `json:"difficulty"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		Moneysupply          float64 `json:"moneysupply"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusGetInfo struct {
	Result struct {
		Version         string  `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Anonbalance     float64 `json:"anonbalance"`
		Reserve         float64 `json:"reserve"`
		Newmint         float64 `json:"newmint"`
		Stake           float64 `json:"stake"`
		Unconfirmed     float64 `json:"unconfirmed"`
		Immature        float64 `json:"immature"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Moneysupply     float64 `json:"moneysupply"`
		Connections     int     `json:"connections"`
		Datareceived    string  `json:"datareceived"`
		Datasent        string  `json:"datasent"`
		Proxy           string  `json:"proxy"`
		IP              string  `json:"ip"`
		Difficulty      struct {
			ProofOfWork  float64 `json:"proof-of-work"`
			ProofOfStake float64 `json:"proof-of-stake"`
		} `json:"difficulty"`
		Netmhashps           float64 `json:"netmhashps"`
		Netstakeweight       float64 `json:"netstakeweight"`
		Weight               int     `json:"weight"`
		Testnet              bool    `json:"testnet"`
		Fortunastake         bool    `json:"fortunastake"`
		Fslock               bool    `json:"fslock"`
		Nativetor            bool    `json:"nativetor"`
		Keypoololdest        int     `json:"keypoololdest"`
		Keypoolsize          int     `json:"keypoolsize"`
		Paytxfee             float64 `json:"paytxfee"`
		Mininput             float64 `json:"mininput"`
		Datadir              string  `json:"datadir"`
		Initialblockdownload bool    `json:"initialblockdownload"`
		UnlockedUntil        int     `json:"unlocked_until"`
		WalletStatus         string  `json:"wallet_status"`
		Errors               string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusGetStakingInfo struct {
	Result struct {
		Enabled          bool    `json:"enabled"`
		Staking          bool    `json:"staking"`
		Errors           string  `json:"errors"`
		Currentblocksize int     `json:"currentblocksize"`
		Currentblocktx   int     `json:"currentblocktx"`
		Pooledtx         int     `json:"pooledtx"`
		Difficulty       float64 `json:"difficulty"`
		SearchInterval   int     `json:"search-interval"`
		Weight           int     `json:"weight"`
		Netstakeweight   int     `json:"netstakeweight"`
		Expectedtime     int     `json:"expectedtime"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusListReceivedByAddress struct {
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

type DenariusListTransactions struct {
	Result []struct {
		Account       string  `json:"account"`
		Address       string  `json:"address"`
		Category      string  `json:"category"`
		Amount        float64 `json:"amount,omitempty"`
		Vout          int     `json:"vout"`
		Label         string  `json:"label"`
		Version       int     `json:"version"`
		Confirmations int     `json:"confirmations"`
		Blockhash     string  `json:"blockhash"`
		Blockindex    int     `json:"blockindex"`
		Blocktime     int     `json:"blocktime"`
		Txid          string  `json:"txid"`
		Time          int     `json:"time"`
		Timereceived  int     `json:"timereceived"`
		Reward        float64 `json:"reward,omitempty"`
		Generated     bool    `json:"generated,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DenariusNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DenariusStakingInfoS struct {
	Result struct {
		Enabled          bool    `json:"enabled"`
		Staking          bool    `json:"staking"`
		Errors           string  `json:"errors"`
		Currentblocksize int     `json:"currentblocksize"`
		Currentblocktx   int     `json:"currentblocktx"`
		Pooledtx         int     `json:"pooledtx"`
		Difficulty       float64 `json:"difficulty"`
		SearchInterval   int     `json:"search-interval"`
		Weight           int     `json:"weight"`
		Netstakeweight   int     `json:"netstakeweight"`
		Expectedtime     int     `json:"expectedtime"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

//type DenariusWalletInfoRespStruct struct {
//	Result struct {
//		Walletname            string  `json:"walletname"`
//		Walletversion         int     `json:"walletversion"`
//		Balance               float64 `json:"balance"`
//		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
//		ImmatureBalance       float64 `json:"immature_balance"`
//		Txcount               int     `json:"txcount"`
//		Keypoololdest         int     `json:"keypoololdest"`
//		Keypoolsize           int     `json:"keypoolsize"`
//		Hdseedid              string  `json:"hdseedid"`
//		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
//		Paytxfee              float64 `json:"paytxfee"`
//		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
//		AvoidReuse            bool    `json:"avoid_reuse"`
//		Scanning              bool    `json:"scanning"`
//		UnlockedUntil         int     `json:"unlocked_until"`
//	} `json:"result"`
//	Error interface{} `json:"error"`
//	ID    string      `json:"id"`
//}

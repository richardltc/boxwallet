package models

import "time"

type DiviAddNodes struct {
	Subver   string   `json:"subver"`
	Protocol int      `json:"protocol"`
	Nodes    []string `json:"nodes"`
}

type DiviBlockchainInfo struct {
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

type DiviDumpHDInfo struct {
	Result struct {
		Hdseed             string `json:"hdseed"`
		Mnemonic           string `json:"mnemonic"`
		Mnemonicpassphrase string `json:"mnemonicpassphrase"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DiviGetInfo struct {
	Result struct {
		Version         string  `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Zerocoinbalance float64 `json:"zerocoinbalance"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Moneysupply     float64 `json:"moneysupply"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		Paytxfee        float64 `json:"paytxfee"`
		Relayfee        float64 `json:"relayfee"`
		StakingStatus   string  `json:"staking status"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DiviGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DiviListReceivedByAddress struct {
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

type DiviListTransactions struct {
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

type DiviLottery struct {
	Lottery struct {
		AverageBlockTime float64 `json:"averageBlockTime"`
		CurrentBlock     int     `json:"currentBlock"`
		NextLotteryBlock int     `json:"nextLotteryBlock"`
		Countdown        struct {
			Milliseconds float64 `json:"milliseconds"`
			Humanized    string  `json:"humanized"`
		} `json:"countdown"`
	} `json:"lottery"`
	Stats string `json:"stats"`
}

type DiviMNSyncStatus struct {
	Result struct {
		IsBlockchainSynced         bool `json:"IsBlockchainSynced"`
		LastMasternodeList         int  `json:"lastMasternodeList"`
		LastMasternodeWinner       int  `json:"lastMasternodeWinner"`
		LastFailure                int  `json:"lastFailure"`
		NCountFailures             int  `json:"nCountFailures"`
		SumMasternodeList          int  `json:"sumMasternodeList"`
		SumMasternodeWinner        int  `json:"sumMasternodeWinner"`
		CountMasternodeList        int  `json:"countMasternodeList"`
		CountMasternodeWinner      int  `json:"countMasternodeWinner"`
		RequestedMasternodeAssets  int  `json:"RequestedMasternodeAssets"`
		RequestedMasternodeAttempt int  `json:"RequestedMasternodeAttempt"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DiviStakingStatus struct {
	Result struct {
		Validtime       bool `json:"validtime"`
		Haveconnections bool `json:"haveconnections"`
		Walletunlocked  bool `json:"walletunlocked"`
		Mintablecoins   bool `json:"mintablecoins"`
		Enoughcoins     bool `json:"enoughcoins"`
		Mnsync          bool `json:"mnsync"`
		StakingStatus   bool `json:"staking status"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DiviTicker struct {
	DIVI struct {
		ID                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         interface{} `json:"max_supply"`
		CirculatingSupply float64     `json:"circulating_supply"`
		TotalSupply       float64     `json:"total_supply"`
		Platform          interface{} `json:"platform"`
		CmcRank           int         `json:"cmc_rank"`
		LastUpdated       time.Time   `json:"last_updated"`
		Quote             struct {
			BTC struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"DIVI"`
}

type DiviWalletInfo struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		EncryptionStatus   string  `json:"encryption_status"`
		Hdchainid          string  `json:"hdchainid"`
		Hdaccountcount     int     `json:"hdaccountcount"`
		Hdaccounts         []struct {
			Hdaccountindex     int `json:"hdaccountindex"`
			Hdexternalkeyindex int `json:"hdexternalkeyindex"`
			Hdinternalkeyindex int `json:"hdinternalkeyindex"`
		} `json:"hdaccounts"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

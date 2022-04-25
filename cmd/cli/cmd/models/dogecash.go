package models

import "time"

type DOGECBlockchainInfo struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
		Softforks            []struct {
			ID      string `json:"id"`
			Version int    `json:"version"`
			Reject  struct {
				Status bool `json:"status"`
			} `json:"reject"`
		} `json:"softforks"`
		Upgrades struct {
			PoS struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PoS"`
			PoSV2 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PoS v2"`
			Zerocoin struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin"`
			ZerocoinV2 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin v2"`
			BIP65 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"BIP65"`
			ZerocoinPublic struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin Public"`
			PIVXV34 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PIVX v3.4"`
			PIVXV41 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PIVX v4.1"`
		} `json:"upgrades"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DOGECGetInfo struct {
	Result struct {
		Version         int     `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Services        string  `json:"services"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Zerocoinbalance float64 `json:"zerocoinbalance"`
		StakingStatus   string  `json:"staking status"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Moneysupply     float64 `json:"moneysupply"`
		ZPIVsupply      struct {
			Num1    float64 `json:"1"`
			Num5    float64 `json:"5"`
			Num10   float64 `json:"10"`
			Num50   float64 `json:"50"`
			Num100  float64 `json:"100"`
			Num500  float64 `json:"500"`
			Num1000 float64 `json:"1000"`
			Num5000 float64 `json:"5000"`
			Total   float64 `json:"total"`
		} `json:"zPIVsupply"`
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

type DOGECGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type DOGECListReceivedByAddress struct {
	Result []struct {
		Address         string        `json:"address"`
		Account         string        `json:"account"`
		Amount          float64       `json:"amount"`
		Confirmations   int           `json:"confirmations"`
		Bcconfirmations int           `json:"bcconfirmations"`
		Label           string        `json:"label"`
		Txids           []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DOGECListTransactions struct {
	Result []struct {
		Address         string        `json:"address"`
		Category        string        `json:"category"`
		Amount          float64       `json:"amount"`
		Label           string        `json:"label"`
		Vout            int           `json:"vout"`
		Confirmations   int           `json:"confirmations"`
		Bcconfirmations int           `json:"bcconfirmations"`
		Blockhash       string        `json:"blockhash"`
		Blockindex      int           `json:"blockindex"`
		Blocktime       int           `json:"blocktime"`
		Txid            string        `json:"txid"`
		Walletconflicts []interface{} `json:"walletconflicts"`
		Time            int           `json:"time"`
		Timereceived    int           `json:"timereceived"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DOGECMNSyncStatus struct {
	Result struct {
		IsBlockchainSynced         bool `json:"IsBlockchainSynced"`
		LastMasternodeList         int  `json:"lastMasternodeList"`
		LastMasternodeWinner       int  `json:"lastMasternodeWinner"`
		LastBudgetItem             int  `json:"lastBudgetItem"`
		LastFailure                int  `json:"lastFailure"`
		NCountFailures             int  `json:"nCountFailures"`
		SumMasternodeList          int  `json:"sumMasternodeList"`
		SumMasternodeWinner        int  `json:"sumMasternodeWinner"`
		SumBudgetItemProp          int  `json:"sumBudgetItemProp"`
		SumBudgetItemFin           int  `json:"sumBudgetItemFin"`
		CountMasternodeList        int  `json:"countMasternodeList"`
		CountMasternodeWinner      int  `json:"countMasternodeWinner"`
		CountBudgetItemProp        int  `json:"countBudgetItemProp"`
		CountBudgetItemFin         int  `json:"countBudgetItemFin"`
		RequestedMasternodeAssets  int  `json:"RequestedMasternodeAssets"`
		RequestedMasternodeAttempt int  `json:"RequestedMasternodeAttempt"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DOGECStakingStatus struct {
	Result struct {
		StakingStatus       bool    `json:"staking_status"`
		StakingEnabled      bool    `json:"staking_enabled"`
		ColdstakingEnabled  bool    `json:"coldstaking_enabled"`
		Haveconnections     bool    `json:"haveconnections"`
		Mnsync              bool    `json:"mnsync"`
		Walletunlocked      bool    `json:"walletunlocked"`
		Stakeablecoins      int     `json:"stakeablecoins"`
		Stakingbalance      float64 `json:"stakingbalance"`
		Stakesplitthreshold float64 `json:"stakesplitthreshold"`
		LastattemptAge      int     `json:"lastattempt_age"`
		LastattemptDepth    int     `json:"lastattempt_depth"`
		LastattemptHash     string  `json:"lastattempt_hash"`
		LastattemptCoins    int     `json:"lastattempt_coins"`
		LastattemptTries    int     `json:"lastattempt_tries"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type DOGECTicker struct {
	DOGEC struct {
		Id                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         interface{} `json:"max_supply"`
		CirculatingSupply float64     `json:"circulating_supply"`
		TotalSupply       float64     `json:"total_supply"`
		IsActive          int         `json:"is_active"`
		Platform          interface{} `json:"platform"`
		CmcRank           int         `json:"cmc_rank"`
		IsFiat            int         `json:"is_fiat"`
		LastUpdated       time.Time   `json:"last_updated"`
		Quote             struct {
			BTC struct {
				Price                 float64   `json:"price"`
				Volume24H             float64   `json:"volume_24h"`
				VolumeChange24H       float64   `json:"volume_change_24h"`
				PercentChange1H       float64   `json:"percent_change_1h"`
				PercentChange24H      float64   `json:"percent_change_24h"`
				PercentChange7D       float64   `json:"percent_change_7d"`
				PercentChange30D      float64   `json:"percent_change_30d"`
				PercentChange60D      float64   `json:"percent_change_60d"`
				PercentChange90D      float64   `json:"percent_change_90d"`
				MarketCap             float64   `json:"market_cap"`
				MarketCapDominance    float64   `json:"market_cap_dominance"`
				FullyDilutedMarketCap float64   `json:"fully_diluted_market_cap"`
				LastUpdated           time.Time `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price                 float64   `json:"price"`
				Volume24H             float64   `json:"volume_24h"`
				VolumeChange24H       float64   `json:"volume_change_24h"`
				PercentChange1H       float64   `json:"percent_change_1h"`
				PercentChange24H      float64   `json:"percent_change_24h"`
				PercentChange7D       float64   `json:"percent_change_7d"`
				PercentChange30D      float64   `json:"percent_change_30d"`
				PercentChange60D      float64   `json:"percent_change_60d"`
				PercentChange90D      float64   `json:"percent_change_90d"`
				MarketCap             float64   `json:"market_cap"`
				MarketCapDominance    float64   `json:"market_cap_dominance"`
				FullyDilutedMarketCap float64   `json:"fully_diluted_market_cap"`
				LastUpdated           time.Time `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"PIVX"`
}

type DOGECWalletInfo struct {
	Result struct {
		Walletversion              int     `json:"walletversion"`
		Balance                    float64 `json:"balance"`
		DelegatedBalance           float64 `json:"delegated_balance"`
		ColdStakingBalance         float64 `json:"cold_staking_balance"`
		UnconfirmedBalance         float64 `json:"unconfirmed_balance"`
		ImmatureBalance            float64 `json:"immature_balance"`
		ImmatureDelegatedBalance   float64 `json:"immature_delegated_balance"`
		ImmatureColdStakingBalance float64 `json:"immature_cold_staking_balance"`
		Txcount                    int     `json:"txcount"`
		UnlockedUntil              int     `json:"unlocked_until"`
		Keypoololdest              int     `json:"keypoololdest"`
		Keypoolsize                int     `json:"keypoolsize"`
		Hdseedid                   string  `json:"hdseedid"`
		KeypoolsizeHdInternal      int     `json:"keypoolsize_hd_internal"`
		KeypoolsizeHdStaking       int     `json:"keypoolsize_hd_staking"`
		Paytxfee                   float64 `json:"paytxfee"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

package models

import "time"

type LTCBlockchainInfo struct {
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
		Softforks            []struct {
			Id      string `json:"id"`
			Version int    `json:"version"`
			Reject  struct {
				Status bool `json:"status"`
			} `json:"reject"`
		} `json:"softforks"`
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
		} `json:"bip9_softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

type LTCGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type LTCListReceivedByAddress struct {
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

type LTCListTransactions struct {
	Result []struct {
		Account         string        `json:"account"`
		Address         string        `json:"address"`
		Category        string        `json:"category"`
		Amount          float64       `json:"amount"`
		Vout            int           `json:"vout,omitempty"`
		Confirmations   int           `json:"confirmations"`
		Blockhash       string        `json:"blockhash"`
		Blockindex      int           `json:"blockindex"`
		Blocktime       int           `json:"blocktime"`
		Txid            string        `json:"txid"`
		Walletconflicts []interface{} `json:"walletconflicts"`
		Time            int           `json:"time"`
		Timereceived    int           `json:"timereceived"`
		Generated       bool          `json:"generated,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type LTCNetworkInfo struct {
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
	Id    string      `json:"id"`
}

type LTCTicker struct {
	LTC struct {
		Id                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         int         `json:"max_supply"`
		CirculatingSupply float64     `json:"circulating_supply"`
		TotalSupply       int         `json:"total_supply"`
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
	} `json:"LTC"`
}

type LTCWalletInfo struct {
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
		UnlockedUntil         int     `json:"unlocked_until"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

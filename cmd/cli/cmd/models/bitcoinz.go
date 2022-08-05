package models

import "time"

type BTCZBlockchainInfo struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
		Pruned               bool    `json:"pruned"`
		SizeOnDisk           int     `json:"size_on_disk"`
		Commitments          int     `json:"commitments"`
		ValuePools           []struct {
			Id            string  `json:"id"`
			Monitored     bool    `json:"monitored"`
			ChainValue    float64 `json:"chainValue"`
			ChainValueZat int64   `json:"chainValueZat"`
		} `json:"valuePools"`
		Softforks []struct {
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
		Upgrades struct {
			Ba81B19 struct {
				Name             string `json:"name"`
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"5ba81b19"`
			B809Bb struct {
				Name             string `json:"name"`
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"76b809bb"`
		} `json:"upgrades"`
		Consensus struct {
			Chaintip  string `json:"chaintip"`
			Nextblock string `json:"nextblock"`
		} `json:"consensus"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

type BTCZListReceivedByAddress struct {
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

type BTCZListTransactions struct {
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
type BTCZNetworkInfo struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Timeoffset      int    `json:"timeoffset"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name                      string `json:"name"`
			Limited                   bool   `json:"limited"`
			Reachable                 bool   `json:"reachable"`
			Proxy                     string `json:"proxy"`
			ProxyRandomizeCredentials bool   `json:"proxy_randomize_credentials"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Localaddresses []interface{} `json:"localaddresses"`
		Warnings       string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

type BTCZGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	Id     string      `json:"id"`
}

type BTCZTicker struct {
	BTCZ struct {
		Id                            int         `json:"id"`
		Name                          string      `json:"name"`
		Symbol                        string      `json:"symbol"`
		Slug                          string      `json:"slug"`
		NumMarketPairs                int         `json:"num_market_pairs"`
		DateAdded                     time.Time   `json:"date_added"`
		Tags                          []string    `json:"tags"`
		MaxSupply                     int64       `json:"max_supply"`
		CirculatingSupply             int64       `json:"circulating_supply"`
		TotalSupply                   int64       `json:"total_supply"`
		IsActive                      int         `json:"is_active"`
		Platform                      interface{} `json:"platform"`
		CmcRank                       int         `json:"cmc_rank"`
		IsFiat                        int         `json:"is_fiat"`
		SelfReportedCirculatingSupply interface{} `json:"self_reported_circulating_supply"`
		SelfReportedMarketCap         interface{} `json:"self_reported_market_cap"`
		TvlRatio                      interface{} `json:"tvl_ratio"`
		LastUpdated                   time.Time   `json:"last_updated"`
		Quote                         struct {
			BTC struct {
				Price                 float64     `json:"price"`
				Volume24H             float64     `json:"volume_24h"`
				VolumeChange24H       float64     `json:"volume_change_24h"`
				PercentChange1H       float64     `json:"percent_change_1h"`
				PercentChange24H      float64     `json:"percent_change_24h"`
				PercentChange7D       float64     `json:"percent_change_7d"`
				PercentChange30D      float64     `json:"percent_change_30d"`
				PercentChange60D      float64     `json:"percent_change_60d"`
				PercentChange90D      float64     `json:"percent_change_90d"`
				MarketCap             float64     `json:"market_cap"`
				MarketCapDominance    int         `json:"market_cap_dominance"`
				FullyDilutedMarketCap float64     `json:"fully_diluted_market_cap"`
				Tvl                   interface{} `json:"tvl"`
				LastUpdated           time.Time   `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price                 float64     `json:"price"`
				Volume24H             float64     `json:"volume_24h"`
				VolumeChange24H       float64     `json:"volume_change_24h"`
				PercentChange1H       float64     `json:"percent_change_1h"`
				PercentChange24H      float64     `json:"percent_change_24h"`
				PercentChange7D       float64     `json:"percent_change_7d"`
				PercentChange30D      float64     `json:"percent_change_30d"`
				PercentChange60D      float64     `json:"percent_change_60d"`
				PercentChange90D      float64     `json:"percent_change_90d"`
				MarketCap             float64     `json:"market_cap"`
				MarketCapDominance    int         `json:"market_cap_dominance"`
				FullyDilutedMarketCap float64     `json:"fully_diluted_market_cap"`
				Tvl                   interface{} `json:"tvl"`
				LastUpdated           time.Time   `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"BTCZ"`
}

type BTCZWalletInfo struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		Paytxfee           float64 `json:"paytxfee"`
		UnlockedUntil      int     `json:"unlocked_until"`
		Seedfp             string  `json:"seedfp"`
	} `json:"result"`
	Error interface{} `json:"error"`
	Id    string      `json:"id"`
}

package models

import "time"

type RDDBlockchainInfo struct {
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

type RDDGetInfo struct {
	Result struct {
		Version         int     `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Stake           float64 `json:"stake"`
		Locked          bool    `json:"locked"`
		Encrypted       bool    `json:"encrypted"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Moneysupply     float64 `json:"moneysupply"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		UnlockedUntil   int     `json:"unlocked_until"`
		Paytxfee        float64 `json:"paytxfee"`
		Relayfee        float64 `json:"relayfee"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

//type RDDGetNewAddress struct {
//	Result []struct {
//		Address       string        `json:"address"`
//		Account       string        `json:"account"`
//		Amount        float64       `json:"amount"`
//		Confirmations int           `json:"confirmations"`
//		Txids         []interface{} `json:"txids"`
//	} `json:"result"`
//	Error interface{} `json:"error"`
//	ID    string      `json:"id"`
//}

type RDDGetNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

// Might need a live update
type RDDListReceivedByAddress struct {
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

type RDDListTransactions struct {
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

type RDDNetworkInfo struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Timeoffset      int    `json:"timeoffset"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name      string `json:"name"`
			Limited   bool   `json:"limited"`
			Reachable bool   `json:"reachable"`
			Proxy     string `json:"proxy"`
		} `json:"networks"`
		Relayfee       float64       `json:"relayfee"`
		Localaddresses []interface{} `json:"localaddresses"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type RDDTicker struct {
	RDD struct {
		ID                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         interface{} `json:"max_supply"`
		CirculatingSupply int64       `json:"circulating_supply"`
		TotalSupply       int64       `json:"total_supply"`
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
	} `json:"RDD"`
}

type RDDWalletInfo struct {
	Result struct {
		Walletversion int     `json:"walletversion"`
		Balance       float64 `json:"balance"`
		Txcount       int     `json:"txcount"`
		Keypoololdest int     `json:"keypoololdest"`
		UnlockedUntil int     `json:"unlocked_until"`
		Keypoolsize   int     `json:"keypoolsize"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

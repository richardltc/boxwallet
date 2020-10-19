package bend

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/dustin/go-humanize"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	cDiviAddNodeURL string = "https://api.diviproject.org/v1/addnode"

	CCoinNameDivi string = "Divi"

	// CDiviAppVersion - The app version of Divi
	//CDiviAppVersion string = "1.1.2"
	CDiviHomeDir    string = ".divi"
	CDiviHomeDirWin string = "DIVI"

	CDiviCoreVersion string = "1.1.2"
	CDFDiviRPi              = "divi-" + CDiviCoreVersion + "-RPi2.tar.gz"
	CDFDiviLinux            = "divi-" + CDiviCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFDiviWindows          = "divi-" + CDiviCoreVersion + "-win64.zip"

	CDiviExtractedDir = "divi-" + CDiviCoreVersion + "/"

	CDownloadURLDivi = "https://github.com/DiviProject/Divi/releases/download/v" + CDiviCoreVersion + "/"

	CDiviConfFile   string = "divi.conf"
	CDiviCliFile    string = "divi-cli"
	CDiviCliFileWin string = "divi-cli.exe"
	CDiviDFile      string = "divid"
	CDiviDFileWin   string = "divid.exe"
	CDiviTxFile     string = "divi-tx"
	CDiviTxFileWin  string = "divi-tx.exe"

	// divi.conf file constants
	CDiviRPCPort string = "51473"

	// Wallet encryption status
	CWalletESUnlockedForStaking = "unlocked-for-staking"
	CWalletESLocked             = "locked"
	CWalletESUnlocked           = "unlocked"
	CWalletESUnencrypted        = "unencrypted"
)

type DiviBlockchainInfoRespStruct struct {
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

type diviGetInfoRespStruct struct {
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

type DiviGetNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}
type DiviListReceivedByAddressRespStruct struct {
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

type LotteryDiviRespStruct struct {
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

type DiviMNSyncStatusRespStruct struct {
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

type DiviStakingStatusRespStruct struct {
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

type DiviTickerStruct struct {
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

type DiviWalletInfoRespStruct struct {
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

var gLastBCSyncPos float64 = 0

func GetBalanceInCurrencyTxtDivi(conf *ConfStruct, wi *DiviWalletInfoRespStruct) string {
	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
	var pricePerCoin float64
	var symbol string

	// Work out what currency
	switch conf.Currency {
	case "AUD":
		symbol = "$"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinAUD.Rates.AUD
	case "USD":
		symbol = "$"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price
	case "GBP":
		symbol = "£"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinGBP.Rates.GBP
	default:
		symbol = "$"
		pricePerCoin = gTicker.DIVI.Quote.USD.Price
	}

	tBalanceCurrency := pricePerCoin * tBalance

	tBalanceCurrencyStr := humanize.FormatFloat("###,###.##", tBalanceCurrency) //humanize.Commaf(tBalanceCurrency) //FormatFloat("#,###.####", tBalanceCurrency)

	// Work out balance
	if wi.Result.ImmatureBalance > 0 {
		return "Incoming......... [" + symbol + tBalanceCurrencyStr + "](fg:cyan)"
	} else if wi.Result.UnconfirmedBalance > 0 {
		return "Confirming....... [" + symbol + tBalanceCurrencyStr + "](fg:yellow)"
	} else {
		return "Currency:         [" + symbol + tBalanceCurrencyStr + "](fg:green)"
	}
}

func GetBlockchainInfoDivi(cliConf *ConfStruct) (DiviBlockchainInfoRespStruct, error) {
	var respStruct DiviBlockchainInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

func GetBlockchainSyncTxtDivi(synced bool, bci *DiviBlockchainInfoRespStruct) string {
	s := ConvertBCVerification(bci.Result.Verificationprogress)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}

	if !synced {
		if bci.Result.Verificationprogress > gLastBCSyncPos {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
		} else {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
		}
	} else {
		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
	}
}

func GetInfoDivi(cliConf *ConfStruct) (diviGetInfoRespStruct, error) {
	attempts := 5
	waitingStr := "Checking server..."

	var respStruct diviGetInfoRespStruct

	for i := 1; i < 50; i++ {
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return respStruct, err
		}
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return respStruct, err
		}

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again...
			var errStruct GenericRespStruct
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func GetMNSyncStatusDivi(cliConf *ConfStruct) (DiviMNSyncStatusRespStruct, error) {
	var respStruct DiviMNSyncStatusRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

func GetMNSyncStatusTxtDivi(mnss *DiviMNSyncStatusRespStruct) string {
	if mnss.Result.RequestedMasternodeAssets == 999 {
		return "Masternodes: [synced " + CUtfTickBold + "](fg:green)"
	} else {
		return "Masternodes: [syncing " + getNextProgMNIndicator(gLastMNSyncStatus) + "](fg:yellow)"
	}
}

func GetNetworkBlocksTxtDivi(bci *DiviBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func GetNetworkDifficultyTxtDivi(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}
	if difficulty >= good {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty >= warn {
		return "[Difficulty:  " + s + "](fg:yellow)"
	} else {
		return "[Difficulty:  " + s + "](fg:red)"
	}
}

func GetNewAddressDivi(cliConf *ConfStruct) (DiviGetNewAddressStruct, error) {
	var respStruct DiviGetNewAddressStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}

	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	return respStruct, nil
}

//func GetNetworkDifficultyTxtDivi(difficulty float64) string {
//	var s string
//	if difficulty > 1000 {
//		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
//	} else {
//		s = humanize.Ftoa(difficulty)
//	}
//	if difficulty > 6000 {
//		return "Difficulty:  [" + s + "](fg:green)"
//	} else if difficulty > 3000 {
//		return "[Difficulty:  " + s + "](fg:yellow)"
//	} else {
//		return "[Difficulty:  " + s + "](fg:red)"
//	}
//}

func GetStakingStatusDivi(cliConf *ConfStruct) (DiviStakingStatusRespStruct, error) {
	var respStruct DiviStakingStatusRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

func GetWalletInfoDivi(cliConf *ConfStruct) (DiviWalletInfoRespStruct, error) {
	var respStruct DiviWalletInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}
	return respStruct, nil
}

func GetWalletSecurityStateDivi(wi *DiviWalletInfoRespStruct) WEType {
	if wi.Result.EncryptionStatus == CWalletESLocked {
		return WETLocked
	} else if wi.Result.EncryptionStatus == CWalletESUnlocked {
		return WETUnlocked
	} else if wi.Result.EncryptionStatus == CWalletESUnlockedForStaking {
		return WETUnlockedForStaking
	} else if wi.Result.EncryptionStatus == CWalletESUnencrypted {
		return WETUnencrypted
	} else {
		return WETUnknown
	}
}

func ListReceivedByAddressDivi(cliConf *ConfStruct, includeZero bool) (DiviListReceivedByAddressRespStruct, error) {
	var respStruct DiviListReceivedByAddressRespStruct

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}

	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	return respStruct, nil
}

func UpdateTickerInfoDivi() error {
	resp, err := http.Get("https://ticker.neist.io/DIVI")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &gTicker)
	if err != nil {
		return err
	}
	return errors.New("unable to updateTicketInfo")
}

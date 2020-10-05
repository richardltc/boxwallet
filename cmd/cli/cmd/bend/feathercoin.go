package bend

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/dustin/go-humanize"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	CCoinNameFeathercoin string = "Feathercoin"

	CFeathercoinCoreVersion string = "0.19.1"
	//CDFFeathercoinRPi       string = "Feathercoin-" + CFeathercoinCoreVersion + "-rPI.zip"
	CDFFeathercoinLinux   string = "feathercoin-" + CFeathercoinCoreVersion + "-linux64.tar.gz"
	CDFFeathercoinWindows string = "feathercoin-" + CFeathercoinCoreVersion + "-win64-setup.exe"

	CFeathercoinExtractedDirLinux = "feathercoin-" + CFeathercoinCoreVersion + "-linux64/"

	CDownloadURLFeathercoin string = "https://github.com/FeatherCoin/FeatherCoin/releases/download/v" + CFeathercoinCoreVersion

	CFeathercoinHomeDir    string = ".feathercoin"
	CFeathercoinHomeDirWin string = "FEATHERCOIN"

	CFeathercoinConfFile   string = "feathercoin.conf"
	CFeathercoinCliFile    string = "feathercoin-cli"
	CFeathercoinCliFileWin string = "feathercoin-cli.exe"
	CFeathercoinDFile      string = "feathercoind"
	CFeathercoinDFileWin   string = "feathercoind.exe"
	CFeathercoinTxFile     string = "feathercoin-tx"
	CFeathercoinTxFileWin  string = "feathercoin-tx.exe"

	// feathercoin.conf file constants
	CFeathercoinRPCPort string = "18332"
)

type FeathercoinBlockchainInfoRespStruct struct {
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
type feathercoinInfoRespStruct struct {
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

type FeathercoinStakingInfoRespStruct struct {
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

type FeathercoinWalletInfoRespStruct struct {
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

func GetBlockchainInfoFeathercoin(cliConf *ConfStruct) (FeathercoinBlockchainInfoRespStruct, error) {
	var respStruct FeathercoinBlockchainInfoRespStruct

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

func GetInfoFeathercoin(cliConf *ConfStruct) (feathercoinInfoRespStruct, error) {
	attempts := 5
	waitingStr := "Checking server..."

	var respStruct feathercoinInfoRespStruct

	for i := 1; i < 50; i++ {
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"getinfo\",\"params\":[]}")
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

func GetNetworkBlocksTxtFeathercoin(bci *FeathercoinBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func GetBlockchainSyncTxtFeathercoin(synced bool, bci *FeathercoinBlockchainInfoRespStruct) string {
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

func GetNetworkDifficultyTxtFeathercoin(difficulty float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}
	if difficulty > 6000 {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty > 3000 {
		return "[Difficulty:  " + s + "](fg:yellow)"
	} else {
		return "[Difficulty:  " + s + "](fg:red)"
	}
}

func GetStakingInfoFeathercoin(cliConf *ConfStruct) (FeathercoinStakingInfoRespStruct, error) {
	var respStruct FeathercoinStakingInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakinginfo\",\"params\":[]}")
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

func GetWalletInfoFeathercoin(cliConf *ConfStruct) (FeathercoinWalletInfoRespStruct, error) {
	var respStruct FeathercoinWalletInfoRespStruct

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

	// Check to see if the json response contains "unlocked_until"
	s := string([]byte(bodyResp))
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func GetWalletSecurityStateFeathercoin(wi *FeathercoinWalletInfoRespStruct) WEType {
	if wi.Result.UnlockedUntil == 0 {
		return WETLocked
	} else if wi.Result.UnlockedUntil == -1 {
		return WETUnencrypted
	} else if wi.Result.UnlockedUntil > 0 {
		return WETUnlockedForStaking
	} else {
		return WETUnknown
	}
}

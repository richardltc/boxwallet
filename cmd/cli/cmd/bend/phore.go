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
	CPhoreCoreVersion string = "1.6.5"
	CDFPhoreRPi              = "phore-" + CPhoreCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	CDFPhoreLinux            = "phore-" + CPhoreCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFPhoreWindows          = "phore-" + CPhoreCoreVersion + "-win64.zip"

	CPhoreExtractedDir = "phore-" + CPhoreCoreVersion + "/"

	CDownloadURLPhore = "https://github.com/phoreproject/Phore/releases/download/v" + CPhoreCoreVersion + "/"

	CCoinNamePhore string = "Phore"

	// Phore Wallet Constants
	CPhoreHomeDir    string = ".phore"
	CPhoreHomeDirWin string = "PHORE"

	CPhoreConfFile   string = "phore.conf"
	CPhoreCliFile    string = "phore-cli"
	CPhoreCliFileWin string = "phore-cli.exe"
	CPhoreDFile      string = "phored"
	CPhoreDFileWin   string = "phored.exe"
	CPhoreTxFile     string = "phore-tx"
	CPhoreTxFileWin  string = "phore-tx.exe"

	// phore.conf file constants
	CPhoreRPCPort string = "11772"
)

type PhoreBlockchainInfoRespStruct struct {
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

type phoreInfoRespStruct struct {
	Result struct {
		Version         int     `json:"version"`
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
		ZPHRsupply      struct {
			Num1    float64 `json:"1"`
			Num5    float64 `json:"5"`
			Num10   float64 `json:"10"`
			Num50   float64 `json:"50"`
			Num100  float64 `json:"100"`
			Num500  float64 `json:"500"`
			Num1000 float64 `json:"1000"`
			Num5000 float64 `json:"5000"`
			Total   float64 `json:"total"`
		} `json:"zPHRsupply"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
		Paytxfee      float64 `json:"paytxfee"`
		Relayfee      float64 `json:"relayfee"`
		StakingStatus string  `json:"staking status"`
		Errors        string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PhoreStakingStatusRespStruct struct {
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
type PhoreWalletInfoRespStruct struct {
	Result struct {
		Walletversion int     `json:"walletversion"`
		Balance       float64 `json:"balance"`
		Txcount       int     `json:"txcount"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
		UnlockedUntil int     `json:"unlocked_until"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PhoreMNSyncStatusRespStruct struct {
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

func GetBlockchainInfoPhore(cliConf *ConfStruct) (PhoreBlockchainInfoRespStruct, error) {
	var respStruct PhoreBlockchainInfoRespStruct

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

func GetBlockchainSyncTxtPhore(synced bool, bci *PhoreBlockchainInfoRespStruct) string {
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

func GetInfoPhore(cliConf *ConfStruct) (phoreInfoRespStruct, error) {
	attempts := 5
	waitingStr := "Checking server..."

	var respStruct phoreInfoRespStruct

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

func GetMNSyncStatusTxtPhore(mnss *PhoreMNSyncStatusRespStruct) string {
	if mnss.Result.RequestedMasternodeAssets == 999 {
		return "Masternodes: [synced " + CUtfTickBold + "](fg:green)"
	} else {
		return "Masternodes: [syncing " + getNextProgMNIndicator(gLastMNSyncStatus) + "](fg:yellow)"
	}
}

func GetNetworkBlocksTxtPhore(bci *PhoreBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func GetNetworkDifficultyTxtPhore(difficulty float64) string {
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

func GetStakingStatusPhore(cliConf *ConfStruct) (PhoreStakingStatusRespStruct, error) {
	var respStruct PhoreStakingStatusRespStruct

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

func GetWalletInfoPhore(cliConf *ConfStruct) (PhoreWalletInfoRespStruct, error) {
	var respStruct PhoreWalletInfoRespStruct

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

func GetMNSyncStatusPhore(cliConf *ConfStruct) (PhoreMNSyncStatusRespStruct, error) {
	var respStruct PhoreMNSyncStatusRespStruct

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

func GetWalletSecurityStatePhore(wi *PhoreWalletInfoRespStruct) WEType {
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

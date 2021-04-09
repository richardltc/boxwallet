package bend

import (
	"bytes"
	"encoding/json"
	"io/ioutil"
	"net/http"
	"strings"
	"time"
)

const (
	CCoinNamePhore   string = "Phore"
	CCoinAbbrevPhore string = "PHR"

	CCoreVersionPhore string = "1.7.0"
	CDFRPiPhore              = "phore-" + CCoreVersionPhore + "-arm-linux-gnueabihf.tar.gz"
	CDFLinuxPhore            = "phore-" + CCoreVersionPhore + "-x86_64-linux-gnu.tar.gz"
	CDFWindowsPhore          = "phore-" + CCoreVersionPhore + "-win64.zip"

	CExtractedDirLinuxPhore   = "phore-" + CCoreVersionPhore + "/"
	CExtractedDirWindowsPhore = "phore-" + CCoreVersionPhore + "\\"

	CDownloadURLPhore = "https://github.com/phoreproject/Phore/releases/download/v" + CCoreVersionPhore + "/"

	// Phore Wallet Constants.
	cHomeDirPhore    string = ".phore"
	cHomeDirWinPhore string = "PHORE"

	cConfFilePhore   string = "phore.conf"
	CCliFilePhore    string = "phore-cli"
	CCliFileWinPhore string = "phore-cli.exe"
	CDFilePhore      string = "phored"
	CDFileWinPhore   string = "phored.exe"
	CTxFilePhore     string = "phore-tx"
	CTxFileWinPhore  string = "phore-tx.exe"

	// phore.conf file constants.
	cRPCUserPhore string = "phorerpc"
	CRPCPortPhore string = "11772"
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

type PhoreListReceivedByAddressRespStruct struct {
	Result []struct {
		Address         string        `json:"address"`
		Account         string        `json:"account"`
		Amount          float64       `json:"amount"`
		Confirmations   int           `json:"confirmations"`
		Bcconfirmations int           `json:"bcconfirmations"`
		Txids           []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PhoreListTransactions struct {
	Result []struct {
		Account         string   `json:"account"`
		Address         string   `json:"address,omitempty"`
		Category        string   `json:"category"`
		Amount          float64  `json:"amount"`
		Vout            int      `json:"vout"`
		Fee             float64  `json:"fee"`
		Confirmations   int      `json:"confirmations"`
		Bcconfirmations int      `json:"bcconfirmations"`
		Generated       bool     `json:"generated"`
		Blockhash       string   `json:"blockhash"`
		Blockindex      int      `json:"blockindex"`
		Blocktime       int      `json:"blocktime"`
		Txid            string   `json:"txid"`
		Walletconflicts []string `json:"walletconflicts"`
		Time            int      `json:"time"`
		Timereceived    int      `json:"timereceived"`
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

func GetInfoPhore(cliConf *ConfStruct) (phoreInfoRespStruct, error) {
	var respStruct phoreInfoRespStruct

	//lf := "/home/pi/.boxwallet/boxwallet.log"
	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
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

		// todo remove the below after bug fixed.
		//s := string(bodyResp)
		//AddToLog(lf, s, false)

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
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

//func GetMNSyncStatusTxtPhore(mnss *PhoreMNSyncStatusRespStruct) string {
//	if mnss.Result.RequestedMasternodeAssets == 999 {
//		return "Masternodes: [synced " + CUtfTickBold + "](fg:green)"
//	} else {
//		return "Masternodes: [syncing " + getNextProgMNIndicator(gLastMNSyncStatus) + "](fg:yellow)"
//	}
//}

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

func ListReceivedByAddressPhore(cliConf *ConfStruct, includeZero bool) (PhoreListReceivedByAddressRespStruct, error) {
	var respStruct PhoreListReceivedByAddressRespStruct

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

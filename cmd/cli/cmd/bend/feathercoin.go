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
	CCoinNameFeathercoin   string = "Feathercoin"
	CCoinAbbrevFeathercoin string = "FTC"

	CCoreVersionFeathercoin string = "0.19.1"
	//CDFFeathercoinRPi       string = "Feathercoin-" + CCoreVersionFeathercoin + "-rPI.zip"
	CDFLinuxFeathercoin   string = "feathercoin-" + CCoreVersionFeathercoin + "-linux64.tar.gz"
	CDFWindowsFeathercoin string = "feathercoin-" + CCoreVersionFeathercoin + "-win64-setup.exe"

	CExtractedDirLinuxFeathercoin = "feathercoin-" + CCoreVersionFeathercoin + "-linux64/"

	CDownloadURLFeathercoin string = "https://github.com/FeatherCoin/FeatherCoin/releases/download/v" + CCoreVersionFeathercoin + "/"

	cHomeDirFeathercoin    string = ".feathercoin"
	cHomeDirWinFeathercoin string = "FEATHERCOIN"

	cConfFileFeathercoin   string = "feathercoin.conf"
	CCliFileFeathercoin    string = "feathercoin-cli"
	CCliFileWinFeathercoin string = "feathercoin-cli.exe"
	CDFileFeathercoin      string = "feathercoind"
	CDFileWinFeathercoin   string = "feathercoind.exe"
	CTxFileFeathercoin     string = "feathercoin-tx"
	CTxFileWinFeathercoin  string = "feathercoin-tx.exe"

	// feathercoin.conf file constants
	cRPCUserFeathercoin string = "feathercoinrpc"
	CRPCPortFeathercoin string = "18332"
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
		Initialblockdownload bool    `json:"initialblockdownload"`
		Chainwork            string  `json:"chainwork"`
		SizeOnDisk           int     `json:"size_on_disk"`
		Pruned               bool    `json:"pruned"`
		Softforks            struct {
			Bip34 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip34"`
			Bip66 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip66"`
			Bip65 struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"bip65"`
			Csv struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"csv"`
			Segwit struct {
				Type   string `json:"type"`
				Active bool   `json:"active"`
				Height int    `json:"height"`
			} `json:"segwit"`
		} `json:"softforks"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type FeathercoinGetNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}
type FeathercoinListReceivedByAddressRespStruct struct {
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

type FTCListTransactions struct {
	Result []struct {
		Address           string        `json:"address"`
		Category          string        `json:"category"`
		Amount            float64       `json:"amount"`
		Label             string        `json:"label"`
		Vout              int           `json:"vout"`
		Confirmations     int           `json:"confirmations"`
		Blockhash         string        `json:"blockhash,omitempty"`
		Blockindex        int           `json:"blockindex,omitempty"`
		Blocktime         int           `json:"blocktime,omitempty"`
		Txid              string        `json:"txid"`
		Walletconflicts   []interface{} `json:"walletconflicts"`
		Time              int           `json:"time"`
		Timereceived      int           `json:"timereceived"`
		Bip125Replaceable string        `json:"bip125-replaceable"`
		Trusted           bool          `json:"trusted,omitempty"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type FeathercoinNetworkInfoRespStruct struct {
	Result struct {
		Version            int      `json:"version"`
		Subversion         string   `json:"subversion"`
		Protocolversion    int      `json:"protocolversion"`
		Localservices      string   `json:"localservices"`
		Localservicesnames []string `json:"localservicesnames"`
		Localrelay         bool     `json:"localrelay"`
		Timeoffset         int      `json:"timeoffset"`
		Networkactive      bool     `json:"networkactive"`
		Connections        int      `json:"connections"`
		Networks           []struct {
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
	ID    string      `json:"id"`
}

type FeathercoinWalletInfoRespStruct struct {
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
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
		AvoidReuse            bool    `json:"avoid_reuse"`
		Scanning              bool    `json:"scanning"`
		UnlockedUntil         int     `json:"unlocked_until"`
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

func GetNetworkInfoFeathercoin(cliConf *ConfStruct) (FeathercoinNetworkInfoRespStruct, error) {
	var respStruct FeathercoinNetworkInfoRespStruct

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnetworkinfo\",\"params\":[]}")

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
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
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

func GetNewAddressFeathercoin(cliConf *ConfStruct) (FeathercoinGetNewAddressStruct, error) {
	var respStruct FeathercoinGetNewAddressStruct

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

func ListReceivedByAddressFeathercoin(cliConf *ConfStruct, includeZero bool) (FeathercoinListReceivedByAddressRespStruct, error) {
	var respStruct FeathercoinListReceivedByAddressRespStruct

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

func ListTransactionsFTC(cliConf *ConfStruct) (FTCListTransactions, error) {
	var respStruct FTCListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandListTransactions + "\",\"params\":[]}")
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

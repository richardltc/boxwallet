package bend

import (
	"encoding/json"
	"io/ioutil"
	"net/http"
	"strings"
)

const (
	CCoinNameScala string = "Scala"

	CScalaCoreVersion string = "4.1.0"
	CDFScalaRPi       string = "arm-" + CScalaCoreVersion + "-rPI.zip"
	CDFScalaLinux     string = "linux-x64-" + CScalaCoreVersion + ".zip"
	CDFScalaWindows   string = "windows-x64-v" + CScalaCoreVersion + ".zip"

	CScalaExtractedDirLinux = "bin/"

	CDownloadURLScala string = "https://github.com/scala-network/Scala/releases/download/v" + CScalaCoreVersion + "/"

	CScalaHomeDir    string = ".scala"
	CScalaHomeDirWin string = "SCALA"

	CScalaConfFile   string = "scala.conf"
	CScalaCliFile    string = "scala-wallet-cli"
	CScalaCliFileWin string = "scala-wallet-cli.exe"
	CScalaDFile      string = "scalad"
	CScalaDFileWin   string = "scalad.exe"
	CScalaTxFile     string = "scala-wallet-rpc"
	CScalaTxFileWin  string = "scala-wallet-rpc.exe"

	CScalaRPCPort string = "11812"
)

type XLABlockCountRespStruct struct {
	ID      string `json:"id"`
	Jsonrpc string `json:"jsonrpc"`
	Result  struct {
		Count     int    `json:"count"`
		Status    string `json:"status"`
		Untrusted bool   `json:"untrusted"`
	} `json:"result"`
}

type XLAGetInfoRespStruct struct {
	ID      string `json:"id"`
	Jsonrpc string `json:"jsonrpc"`
	Result  struct {
		AltBlocksCount            int    `json:"alt_blocks_count"`
		BlockSizeLimit            int    `json:"block_size_limit"`
		BlockSizeMedian           int    `json:"block_size_median"`
		BlockWeightLimit          int    `json:"block_weight_limit"`
		BlockWeightMedian         int    `json:"block_weight_median"`
		BootstrapDaemonAddress    string `json:"bootstrap_daemon_address"`
		Credits                   int    `json:"credits"`
		CumulativeDifficulty      int64  `json:"cumulative_difficulty"`
		CumulativeDifficultyTop64 int    `json:"cumulative_difficulty_top64"`
		DatabaseSize              int    `json:"database_size"`
		Difficulty                int    `json:"difficulty"`
		DifficultyTop64           int    `json:"difficulty_top64"`
		FreeSpace                 int64  `json:"free_space"`
		GreyPeerlistSize          int    `json:"grey_peerlist_size"`
		Height                    int    `json:"height"`
		HeightWithoutBootstrap    int    `json:"height_without_bootstrap"`
		IncomingConnectionsCount  int    `json:"incoming_connections_count"`
		Mainnet                   bool   `json:"mainnet"`
		Nettype                   string `json:"nettype"`
		Offline                   bool   `json:"offline"`
		OutgoingConnectionsCount  int    `json:"outgoing_connections_count"`
		RPCConnectionsCount       int    `json:"rpc_connections_count"`
		Stagenet                  bool   `json:"stagenet"`
		StartTime                 int    `json:"start_time"`
		Status                    string `json:"status"`
		Target                    int    `json:"target"`
		TargetHeight              int    `json:"target_height"`
		Testnet                   bool   `json:"testnet"`
		TopBlockHash              string `json:"top_block_hash"`
		TopHash                   string `json:"top_hash"`
		TxCount                   int    `json:"tx_count"`
		TxPoolSize                int    `json:"tx_pool_size"`
		Untrusted                 bool   `json:"untrusted"`
		UpdateAvailable           bool   `json:"update_available"`
		Version                   string `json:"version"`
		WasBootstrapEverUsed      bool   `json:"was_bootstrap_ever_used"`
		WhitePeerlistSize         int    `json:"white_peerlist_size"`
		WideCumulativeDifficulty  string `json:"wide_cumulative_difficulty"`
		WideDifficulty            string `json:"wide_difficulty"`
	} `json:"result"`
}

type XLAStopDaemonRespStruct struct {
	Status    string `json:"status"`
	Untrusted bool   `json:"untrusted"`
}

func GetBlockCountXLA(cliConf *ConfStruct) (XLABlockCountRespStruct, error) {
	var respStruct XLABlockCountRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"2.0\",\"id\":\"boxwallet\",\"method\":\"get_block_count\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port+"/json_rpc", body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
	req.Header.Set("Content-Type", "application/json")

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

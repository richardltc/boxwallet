package models

import "time"

const (
	// General CLI command constants.

	CCommandBackupWallet          string = "backupwallet"
	CCommandCreateWallet          string = "createwallet"
	CCommandEncryptWallet         string = "encryptwallet"
	CCommandGetBCInfo             string = "getblockchaininfo"
	CCommandGetInfo               string = "getinfo"
	CCommandGetStakingInfo        string = "getstakinginfo"
	CCommandListReceivedByAddress string = "listreceivedbyaddress"
	CCommandListTransactions      string = "listtransactions"
	CCommandLoadWallet            string = "loadwallet"
	CCommandGetNetworkInfo        string = "getnetworkinfo"
	CCommandGetNewAddress         string = "getnewaddress"
	CCommandGetWalletInfo         string = "getwalletinfo"
	CCommandSendToAddress         string = "sendtoaddress"
	CCommandSetTxFee              string = "settxfee"
	CCommandStop                  string = "stop"

	//CCommandMNSyncStatus1 string = "mnsync"
	//CCommandMNSyncStatus2 string = "status"
	//CCommandDumpHDInfo    string = "dumphdinfo" // ./divi-cli dumphdinfo

	CRPCUser     string = "rpcuser"
	CRPCPassword string = "rpcpassword"
)

// ProjectType - To allow external to determine what kind of wallet we are working with.
type ProjectType int

const (
	PTDivi ProjectType = iota
	PTPhore
	PTPIVX
	PTTrezarcoin
	PTFeathercoin
	PTVertcoin
	PTGroestlcoin
	PTScala
	PTDeVault
	PTReddCoin
	PTRapids
	PTDigiByte
	PTDenarius
	PTSyscoin
	PTBitcoinPlus
	PTPeercoin
	PTPrimecoin
	PTSpiderByte
	PTLitecoin
	PTNavcoin
	PTDogeCash
)

type GenericResponse struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type CoinAuth struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

type GithubInfo struct {
	URL       string `json:"url"`
	AssetsURL string `json:"assets_url"`
	UploadURL string `json:"upload_url"`
	HTMLURL   string `json:"html_url"`
	ID        int    `json:"id"`
	Author    struct {
		Login             string `json:"login"`
		ID                int    `json:"id"`
		NodeID            string `json:"node_id"`
		AvatarURL         string `json:"avatar_url"`
		GravatarID        string `json:"gravatar_id"`
		URL               string `json:"url"`
		HTMLURL           string `json:"html_url"`
		FollowersURL      string `json:"followers_url"`
		FollowingURL      string `json:"following_url"`
		GistsURL          string `json:"gists_url"`
		StarredURL        string `json:"starred_url"`
		SubscriptionsURL  string `json:"subscriptions_url"`
		OrganizationsURL  string `json:"organizations_url"`
		ReposURL          string `json:"repos_url"`
		EventsURL         string `json:"events_url"`
		ReceivedEventsURL string `json:"received_events_url"`
		Type              string `json:"type"`
		SiteAdmin         bool   `json:"site_admin"`
	} `json:"author"`
	NodeID          string    `json:"node_id"`
	TagName         string    `json:"tag_name"`
	TargetCommitish string    `json:"target_commitish"`
	Name            string    `json:"name"`
	Draft           bool      `json:"draft"`
	Prerelease      bool      `json:"prerelease"`
	CreatedAt       time.Time `json:"created_at"`
	PublishedAt     time.Time `json:"published_at"`
	Assets          []struct {
		URL      string `json:"url"`
		ID       int    `json:"id"`
		NodeID   string `json:"node_id"`
		Name     string `json:"name"`
		Label    string `json:"label"`
		Uploader struct {
			Login             string `json:"login"`
			ID                int    `json:"id"`
			NodeID            string `json:"node_id"`
			AvatarURL         string `json:"avatar_url"`
			GravatarID        string `json:"gravatar_id"`
			URL               string `json:"url"`
			HTMLURL           string `json:"html_url"`
			FollowersURL      string `json:"followers_url"`
			FollowingURL      string `json:"following_url"`
			GistsURL          string `json:"gists_url"`
			StarredURL        string `json:"starred_url"`
			SubscriptionsURL  string `json:"subscriptions_url"`
			OrganizationsURL  string `json:"organizations_url"`
			ReposURL          string `json:"repos_url"`
			EventsURL         string `json:"events_url"`
			ReceivedEventsURL string `json:"received_events_url"`
			Type              string `json:"type"`
			SiteAdmin         bool   `json:"site_admin"`
		} `json:"uploader"`
		ContentType        string    `json:"content_type"`
		State              string    `json:"state"`
		Size               int       `json:"size"`
		DownloadCount      int       `json:"download_count"`
		CreatedAt          time.Time `json:"created_at"`
		UpdatedAt          time.Time `json:"updated_at"`
		BrowserDownloadURL string    `json:"browser_download_url"`
	} `json:"assets"`
	TarballURL string `json:"tarball_url"`
	ZipballURL string `json:"zipball_url"`
	Body       string `json:"body"`
}

type WEType int

const (
	WETUnencrypted WEType = iota
	WETLocked
	WETUnlocked
	WETUnlockedForStaking
	WETUnknown
)

// WLSType - Wallet loading status type, calculated at different stages as the wallet loads?
type WLSType int

const (
	WLSTUnknown WLSType = iota
	WLSTReady
	WLSTLoading
	WLSTRescanning
	WLSTRewinding
	WLSTVerifying
	WLSTCalculatingMoneySupply
	WLSTWaitingForResponse
	WLSTRPCInWarmUp
)

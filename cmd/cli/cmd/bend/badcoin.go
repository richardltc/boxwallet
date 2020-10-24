package bend

const (
	CCoinNameBadcoin string = "Badcoin"

	CBadcoinHomeDir    string = ".badcoin"
	CBadcoinHomeDirWin string = "Badcoin"

	CBadcoinCoreVersion string = "0.16.3-2"
	CDFBadcoinRPi              = "divi-" + CBadcoinCoreVersion + "-RPi2.tar.gz"
	CDFBadcoinLinux            = "divi-" + CBadcoinCoreVersion + "Badcoin-x86_64-unknown-linux-gnu.zip"
	CDFBadcoinWindows          = "divi-" + CBadcoinCoreVersion + "-win64.zip"

	CBadcoinExtractedDir = "divi-" + CBadcoinCoreVersion + "/"

	CDownloadURLBadcoin = "https://github.com/badcoin-net/Badcoin/releases/download/v" + CBadcoinCoreVersion + "/"

	CBadcoinConfFile   string = "divi.conf"
	CBadcoinCliFile    string = "divi-cli"
	CBadcoinCliFileWin string = "divi-cli.exe"
	CBadcoinDFile      string = "divid"
	CBadcoinDFileWin   string = "divid.exe"
	CBadcoinTxFile     string = "divi-tx"
	CBadcoinTxFileWin  string = "divi-tx.exe"

	// divi.conf file constants
	CBadcoinRPCPort string = "51473"
)

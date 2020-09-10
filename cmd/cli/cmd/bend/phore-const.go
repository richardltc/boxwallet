package bend

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
)

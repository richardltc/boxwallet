package bend

const (
	CCoinNameRapids string = "Rapids"

	CRapidsCoreVersion string = "3.1"

	CDFRapidsRPi     string = "Rapids-v" + CRapidsCoreVersion + "-arm64.tar.gz"
	CDFRapidsLinux   string = "Rapids-v" + CRapidsCoreVersion + "-linux-1804.tar.gz"
	CDFRapidsWindows string = "Rapids-v" + CRapidsCoreVersion + "-win64.zip"

	CRapidsExtractedDirLinux = "Rapids-" + CRapidsCoreVersion + "/"

	CDownloadURLRapids string = "https://github.com/RapidsOfficial/Rapids/releases/download/v" + CRapidsCoreVersion + "/"
	CRapidsHomeDir     string = ".rapids"
	CRapidsHomeDirWin  string = "RAPIDS"

	CRapidsConfFile   string = "rapids.conf"
	CRapidsCliFile    string = "rapids-cli"
	CRapidsCliFileWin string = "rapids-cli.exe"
	CRapidsDFile      string = "rapidsd"
	CRapidsDFileWin   string = "rapidsd.exe"
	CRapidsTxFile     string = "rapids-tx"
	CRapidsTxFileWin  string = "rapids-tx.exe"

	cRapidsRPCUser string = "rapidsrpc"
	CRapidsRPCPort string = "28732"
)

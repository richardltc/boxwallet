package main

import (
	"crypto/tls"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	//_ "github.com/go-sql-driver/mysql"
	//_ "github.com/lib/pq"

	"github.com/golangcollege/sessions"
	gwc "github.com/richardltc/gwcommon"
	"richardmace.co.uk/godivi/cmd/web/bend"
	"richardmace.co.uk/godivi/pkg/models/op"
)

type application struct {
	errorLog *log.Logger
	infoLog  *log.Logger
	session  *sessions.Session
	wallet   *op.WalletModel
	//agents   *op.AgentModel
	//sites    *op.SiteModel
	//users    *op.UserModel
}

func main() {
	sConf, err := gwc.GetServerConfStruct() //SGetServerConfigStruct(true)
	if err != nil {
		log.Fatal("Unable to GetServerConfStruct " + err.Error())
	}
	if sConf.FirstTimeRun {
		abf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
		if err != nil {
			log.Fatal("Unable to GetAppsBinFolder " + err.Error())
		}

		// We often need to run an initial coindaemon so that it can set it's self up.
		// I think this is the best place to do it, so lets do that now
		err = bend.RunInitialDaemon()
		if err != nil {
			log.Fatal("Unable to RunInitialDaemon " + err.Error())
		}

		sConf.FirstTimeRun = false
		sConf.BinFolder = abf
		err = gwc.SetServerConfStruct(sConf)
		if err != nil {
			log.Fatal("Unable to SetServerCOnfStruct " + err.Error())
		}
	}

	//addr := flag.String("addr", ":4000", "HTTP network address")
	//dsn := flag.String("dsn", "user=rocknet password=rocknet dbname=rocknet sslmode=disable", "Postgres data source name")
	secret := flag.String("secret", "s6Ndh+pPbnzHbS*+9Pk8qGWhTzbpa@ge", "Secret key")
	flag.Parse()

	infoLog := log.New(os.Stdout, "INFO\t", log.Ldate|log.Ltime)
	errorLog := log.New(os.Stderr, "ERROR\t", log.Ldate|log.Ltime|log.Lshortfile)

	session := sessions.New([]byte(*secret))
	session.Lifetime = 12 * time.Hour
	session.Secure = true

	app := &application{
		errorLog: errorLog,
		infoLog:  infoLog,
		session:  session,
	}

	tlsConfig := &tls.Config{
		PreferServerCipherSuites: true,
		CurvePreferences:         []tls.CurveID{tls.X25519, tls.CurveP256},
	}

	srv := &http.Server{
		Addr:      ":" + sConf.Port, //*addr,
		ErrorLog:  errorLog,
		Handler:   app.routes(),
		TLSConfig: tlsConfig,

		// Add Idle, Read and Write timeouts to the server.

		//IdleTimeout:  time.Minute,
		//ReadTimeout:  5 * time.Second,
		//WriteTimeout: 10 * time.Second,

		// using long timeouts for development
		IdleTimeout:  time.Hour,
		ReadTimeout:  time.Hour,
		WriteTimeout: time.Hour,
	}

	sAppServerame, err := gwc.GetAppServerName(gwc.APPTServer)
	if err != nil {
		log.Fatal("Unable to GetAppServerName " + err.Error())
	}

	infoLog.Printf("Starting "+sAppServerame+" version "+gwc.CAppVersion+" on port %s", sConf.Port)

	err = srv.ListenAndServe()
	//err = srv.ListenAndServeTLS("./tls/cert.pem", "./tls/key.pem")
	errorLog.Fatal(err)
}

package main

import (
	"net/http"

	"github.com/bmizerany/pat"
	"github.com/justinas/alice"
)

func (app *application) routes() http.Handler {
	// Create a middleware chain that is executed on all application routes
	standardMiddleware := alice.New(app.recoverPanic, app.logRequest, secureHeaders)

	// Create a new middleware chain containing the middleware specific to our dynamic application routes.
	dynamicMiddleware := alice.New(app.session.Enable)

	mux := pat.New()
	mux.Get("/", dynamicMiddleware.ThenFunc(app.home))

	mux.Get("/server/", dynamicMiddleware.ThenFunc(app.serverRequest))
	mux.Post("/server/", dynamicMiddleware.ThenFunc(app.serverRequest))

	mux.Get("/wallet/", dynamicMiddleware.ThenFunc(app.walletRequest))
	mux.Post("/wallet/", dynamicMiddleware.ThenFunc(app.walletRequest))

	return standardMiddleware.Then(mux)
}

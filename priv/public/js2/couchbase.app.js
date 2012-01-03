var App = (function () {

  Router.pre(function(args) {

    if (args.path === '#/login/') {
      return true;
    }

    if (User.requiresLogin && localJSON.get('auth', null) !== null) {
      User.autoLogin();
    }

    if (User.requiresLogin) {
      LoginView.render();
      return false;
    }

  });

//  Router.post('#/login/', User, User.login);
//  Router.post('#/logout/', User, User.logout);
//
//  // Home page goes to cluster overview
//  Router.get(/^#(\/)?$/, this, function() {
//    document.location.href = '#/cluster/';
//  });
//
//  Router.get('#/cluster/', ClusterView, ClusterView.show);
//  Router.get('#/servers/', ServersView, ServersView.render);
//  Router.get('#/buckets/', BucketsView, BucketsView.render);
//  Router.get('#/settings/:section/', SettingsView, SettingsView.render);
//  Router.get('#/settings/', SettingsView, SettingsView.render);
//
//  Router.get(/.*/, FourOhFourView, FourOhFourView.render);
//
//  Router.init();
})();

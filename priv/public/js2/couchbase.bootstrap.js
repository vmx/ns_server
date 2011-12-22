// Basic wrapper for localStorage
var localJSON = (function(){
  if (!localStorage) {
    return false;
  }
  return {
    set:function(prop, val) {
      localStorage.setItem(prop, JSON.stringify(val));
    },
    get:function(prop, def) {
      return JSON.parse(localStorage.getItem(prop) || 'false') || def;
    },
    remove:function(prop) {
      localStorage.removeItem(prop);
    }
  };
})();


var User = {

  requiresLogin: true,
  auth: null,

  autoLogin: function() {
    return this.doLogin(localJSON.get('auth'));
  },

  login: function(e, form) {

    // Currently this doesnt do anything as the submit button
    // is an image, change that
    var $login_btn = $(e.target).find('input[type=submit]')
      .text('Logging in').attr('disabled', true);

    var auth = 'Basic ' + Base64.encode(form.username + ':' + form.password);
    if (this.doLogin(auth)) {
      Router.refresh();
    } else {
      $login_btn.removeAttr('disabled').text('Sign In');
      $(e.target).find('#login-failed').show();
    }
  },

  logout: function(e, form) {
    this.auth = null;
    this.requiresLogin = true;
    localJSON.remove('auth');
    Router.refresh();
  },

  doLogin: function(auth) {

    var self = this;
    this.auth = auth;

    function cb(data, status) {

      if (status === 'success') {
        localJSON.set('auth', self.auth);
        self.requiresLogin = false;
      } else {
        self.auth = null;
      }
    }

    $.ajax({
      type: 'GET',
      url: "/pools",
      dataType: 'json',
      async: false,
      success: cb,
      error: cb
    });

    return this.auth !== null;
  }
};


$.ajaxSetup({
  cache: false,
  beforeSend: function (xhr, options) {

    // NOTE: we're not sending auth header for capi requests because
    // at this point CAPI is authless and sending auth header only
    // confuses it
    if (User.auth && !(/^\/couchBase/.test(options.url))) {
      xhr.setRequestHeader('Authorization', User.auth);
    }

    xhr.setRequestHeader('invalid-auth-response', 'on');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
  }

});

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

  Router.post('#/login/', User, User.login);
  Router.post('#/logout/', User, User.logout);

  Router.get('#/cluster/', ClusterView, ClusterView.show);
  Router.get('#/servers/', ServersView, ServersView.render);
  Router.get('#/buckets/', BucketsView, BucketsView.render);
  Router.get('#/views/', ViewsView, ViewsView.render);
  Router.get('#/logs/', LogView, LogView.load);
  Router.get('#/settings/:section/', SettingsView, SettingsView.render);
  Router.get('#/settings/', SettingsView, SettingsView.render);

  Router.get(/.*/, FourOhFourView, FourOhFourView.render);

  Router.init();

})();
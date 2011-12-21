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
    return this.login(localJSON.get('auth'));
  },

  login: function(auth) {

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
  },

  load: function(_, e, form) {
    var auth = 'Basic ' + Base64.encode(form.username + ':' + form.password);
    if (this.login(auth)) {
      Router.refresh();
    }
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

    if (args.details.path === '#/login/') {
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


  // These should point to particular functions, not a plain object
  Router.post('#/login/', User);

  Router.get('#/logs/', LogView);
  Router.get('#/cluster/', ClusterView);
  Router.get(/.*/, FourOhFourView);

  Router.init();

})();
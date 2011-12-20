
// This is the main layout as a template
var MainView = View.extend({
  container: '#global_wrapper',
  template: 'main'
});


// This is a object for subviews of the main layout
var AppView = View.extend({

  currentPage: null,
  parent: MainView,
  container: '#content',

  // Now that we have basic template inheritance, this can be redone
  postRender: function(oldView, newView) {

    if (AppView.currentPage) {
      $(document.body).removeClass('page-' + AppView.currentPage);
    }

    if (this.name) {
      $(document.body).addClass('page-' + this.name);
      AppView.currentPage = this.name;
    }
  }

});

var LoginView = AppView.extend({
  template: 'login'
});

var FourOhFourView = AppView.extend({
  template: 'fourohfour'
});

var ClusterView = AppView.extend({
  name: 'cluster',
  template: 'cluster'
});


var LogView = AppView.extend({

  name: 'logs',
  template: 'logs',

  load: function() {
    this.interval = setInterval(function() { LogView.fetchLogs(); }, 5000);
    this.fetchLogs();
  },

  unload: function() {
    clearInterval(this.interval);
  },

  fetchLogs: function() {
    $.get('/logs', function(data) {
      LogView.logs = data.list.reverse();
      LogView.render();
    });
  }

});

var User = {

  requiresLogin: true,
  username: null,
  password: null,

  credentials: function() {
    return {username: this.username, password: this.password};
  },

  load: function(_, e, form) {

    var self = this;

    this.username = form.username;
    this.password = form.password;

    function cb(data, status) {
      if (status === 'success') {
        self.requiresLogin = false;
        Router.refresh();
      } else {
        self.username = null;
        self.password = null;
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

  }

};


$.ajaxSetup({
  cache: false,
  beforeSend: function (xhr, options) {

    // NOTE: we're not sending auth header for capi requests because
    // at this point CAPI is authless and sending auth header only
    // confuses it
    var user = User.credentials();

    if (user && !(/^\/couchBase/.test(options.url))) {
      var auth = 'Basic ' + Base64.encode(user.username + ':' + user.password);
      xhr.setRequestHeader('Authorization', auth);
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

    if (User.requiresLogin) {
      LoginView.render();
      return false;
    }

  });

  Router.post('#/login/', User);

  Router.get('#/logs/', LogView);
  Router.get('#/cluster/', ClusterView);
  Router.get(/.*/, FourOhFourView);

  Router.init();

})();
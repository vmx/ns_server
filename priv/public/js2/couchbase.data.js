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

var Data = {};

Data.poolDetails = {
  data: null
};

Data.buckets = Ember.Object.create({
  data: null,

  names: function() {
    var buckets = this.get('data');
    if (buckets===null) {
      return ['this one is empty'];
    }
    return $.map(buckets, function(bucket) {
      return bucket.name;
    });
  }.property('data')
});

Data.logs = Ember.Object.create({
  data: null
});

Data.fetch = {
  // without Ember object
  poolDetails: (function() {
    this.interval = null;

    function fetch() {
      $.get('/pools/default', function(data) {
        Data.poolDetails.data = data;
        // Workaround for now. The Router.refresh shouldn't really delete
        // input fields
        if (User.auth!==null) {
          Router.refresh();
        }
      });
    }

    fetch();
    this.interval = setInterval(fetch, 5000);

    return this;
  })(),
  // with Ember object
  buckets: (function() {
    this.interval = null;

    function fetch() {
      $.get('/pools/default/buckets', function(data) {
        Data.buckets.set('data', data);
        // Workaround for now. The Router.refresh shouldn't really delete
        // input fields
        if (User.auth!==null) {
          Router.refresh();
        }
      });
    }

    fetch();
    this.interval = setInterval(fetch, 5000);

    return this;
  })(),
  logs: function() {
    $.get('/logs', function(data) {
      Data.logs.set('data', data.list.reverse());
    });
  }
};




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

Handlebars.registerHelper('date', function(date) {
  return Utils.formatLogTStamp(date);
});

Handlebars.registerHelper('formatMem', function(size) {
  return Utils.formatMemSize(size || 0);
});

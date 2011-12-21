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

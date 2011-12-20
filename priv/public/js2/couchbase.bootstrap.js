var View = (function() {

  var currentView;

  this.renderTo = function(to) {
    var source   = $('#' + this.template + '-tpl').html();
    var template = Handlebars.compile(source);
    to.empty().append(template(this));
    if (this.postRender) {
      this.postRender(currentView, this);
    }
    currentView = this;
  }

  this.render = function() {
    this.renderTo($(this.container));
  }

  this.extend = function(obj) {
    return $.extend({}, this, obj);
  }

  this.currentView = function() {
    return currentView;
  }

  return {
    extend: this.extend,
    renderTo: this.renderTo,
    render: this.render,
    currentView: this.currentView
  };

})();


var AppView = View.extend({

  container: $('#content'),

  postRender: function(oldView, newView) {

    if (oldView && oldView.name) {
      $(document.body).removeClass('page-' + oldView.name);
    }

    if (newView.name) {
      $(document.body).addClass('page-' + newView.name);
    }
  }

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


var App = (function () {

  Router.get('#/logs/', LogView);
  Router.get('#/cluster/', ClusterView);
  Router.get(/.*/, FourOhFourView);

  Router.init();

})();
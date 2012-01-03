/*
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


var GuageView = View.extend({template: 'gauge'});
var RamOverView = GuageView.extend({data: {
  title: "RAM Overview",
  neTitle: 'Total Allocated',
  nwTitle: 'Total in Cluster',
  seTitle: 'In Use',
  sTitle: 'Unused',
  swTitle: 'Unallocated'
}});
var DiskOverView = GuageView.extend({data: {
  title: "Disk Overview",
  neTitle: 'Usable Free Space',
  nwTitle: 'Total Cluster Storage',
  seTitle: 'In Use',
  sTitle: 'Other Data',
  swTitle: 'Free'
}});

var ClusterView = AppView.extend({
  name: 'cluster',
  template: 'cluster',
  show: function() {

    if (Data.poolDetails.data.storageTotals) {

      var hdd = Data.poolDetails.data.storageTotals.hdd;
      var ram = Data.poolDetails.data.storageTotals.ram;
      var other = hdd.used - hdd.usedByData;

      RamOverView.data.neVal = ram.quotaUsed;
      RamOverView.data.nwVal = ram.quotaTotal;
      RamOverView.data.seVal = ram.usedByData;
      RamOverView.data.sVal = ram.quotaUsed - ram.usedByData;
      RamOverView.data.swVal = ram.quotaTotal - ram.quotaUsed;
      RamOverView.data.meterColor = '#7EDB49';
      RamOverView.data.meterWidth = (ram.quotaUsed / ram.quotaTotal) * 100;
      RamOverView.data.pointer = (ram.quotaUsed / ram.quotaTotal) * 100;


      DiskOverView.data.neVal = hdd.free;
      DiskOverView.data.nwVal = hdd.total;
      DiskOverView.data.seVal = hdd.usedByData;
      DiskOverView.data.sVal = other;
      DiskOverView.data.swVal = hdd.total - other - hdd.usedByData;
      DiskOverView.data.meterColor = '#FDC90D';
      DiskOverView.data.meterWidth = (other / hdd.total) * 100;
      DiskOverView.pointer = 100;

    }

    this.data.ramGauge = RamOverView.render();
    this.data.diskGauge = DiskOverView.render();
    this.render();
  }
});
*/

// NOTE vmx: here is where the Ember part starts


// NOTE vmx: I'm not happy doing this ugly document.ready wrapping,
// but I just want to have it work in Firefox for now :)
$(document).ready(function() {

// This is the main layout as a template
var MainEmberView = Ember.View.create({
  container: '#global_wrapper',
  templateName: 'foomain-tpl'
});
MainEmberView.appendTo('#global_wrapper');

window.EmberApp = Ember.Application.create({
  rootElement: '#global_wrapper'
});


EmberApp.Views = {};

EmberApp.Views.ViewsView = Ember.ViewState.create({
  view: Ember.View.create({
    templateName: 'views-tpl',
    bucketsBinding: Ember.Binding.oneWay('Data.buckets.names')
  })
});

EmberApp.Views.NotFoundView = Ember.ViewState.create({
  view: Ember.View.create({
    templateName: 'fourohfour-tpl'
  })
});

EmberApp.Views.LogsView = Ember.ViewState.create({
  interval: null,

  view: Ember.View.create({
    templateName: 'logs-tpl',
    logsBinding: Ember.Binding.oneWay('Data.logs.data')
  }),
  enter: function(stateManager) {
    Data.fetch.logs();
    this.interval = setInterval(function() { Data.fetch.logs(); }, 5000);

    this._super(stateManager);
  },
  exit: function(stateManager) {
    clearInterval(this.interval);

    this._super(stateManager);
  }
});


EmberApp.Views.ViewsManager = Ember.StateManager.create({
  rootElement: '#content',
  views: EmberApp.Views.ViewsView,
  notfound: EmberApp.Views.NotFoundView,
  logs: EmberApp.Views.LogsView
});


EmberApp.router = Ember.Object.create({
  initRouter: function() {
    SC.routes.add('/:page/', EmberApp, this.pages);
    SC.routes.add('*url', EmberApp, this.home);
    return SC.routes;
  },
  pages: function(params) {
    // NOTE vmx: Not sure if .get() works cross browser
    if (EmberApp.Views.ViewsManager.get(params.page) !== undefined) {
      return EmberApp.Views.ViewsManager.goToState(params.page);
    }
    return EmberApp.Views.ViewsManager.goToState('notfound');
  },
  home: function(params) {
    // NOTE vmx: Should of course be the start page. This is only for
    // demo purpose
    return EmberApp.Views.ViewsManager.goToState('logs');
  }
});

EmberApp.router.initRouter();

});
